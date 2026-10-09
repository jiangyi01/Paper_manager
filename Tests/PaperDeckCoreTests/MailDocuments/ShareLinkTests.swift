import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ShareLinkTests {
    private func m(_ s: String) -> ShareLinks.Match? { ShareLinks.match(URL(string: s)!) }

    @Test func sharePointAndOneDriveFileLinks() {
        #expect(m("https://gowustl-my.sharepoint.com/:w:/g/personal/jsmith_wustl_edu/EaBc?e=x")
                == .init(provider: .sharepoint, documentKind: "docx", fileName: nil))
        #expect(m("https://gowustl-my.sharepoint.com/:p:/g/personal/j/Eb")?.documentKind == "pptx")
        #expect(m("https://wustl.sharepoint.com/:b:/s/lab/Ec")?.documentKind == "pdf")
        #expect(m("https://wustl.sharepoint.com/:f:/s/lab/Ed")?.provider == .sharepoint)          // a folder
        #expect(m("https://gowustl-my.sharepoint.com/personal/j/_layouts/15/onedrive.aspx?id=%2Fpersonal%2Fj%2FDocuments%2FDraft%2Edocx")
                == .init(provider: .sharepoint, documentKind: "docx", fileName: "Draft.docx"))
        #expect(m("https://wustl.sharepoint.com/sites/lab/_layouts/15/Doc.aspx?sourcedoc=%7Babc%7D&file=Manuscript.docx")?.fileName
                == "Manuscript.docx")
        #expect(m("https://wustl.sharepoint.com/sites/lab/Shared%20Documents/Paper%20v2.docx")?.documentKind == "docx")
        #expect(m("https://1drv.ms/w/s!AbCdEf")?.documentKind == "docx")
        #expect(m("https://1drv.ms/b/s!AbCdEf")?.documentKind == "pdf")
        #expect(m("https://onedrive.live.com/?cid=ABC&resid=ABC%21123")?.provider == .onedrive)
        #expect(m("https://onedrive.live.com/redir?resid=1")?.provider == .onedrive)
    }

    @Test func notFilesOrNotReadingMaterial() {
        for url in [
            "https://gowustl-my.sharepoint.com/:x:/g/personal/j/Ex",            // Excel
            "https://gowustl-my.sharepoint.com/:v:/g/personal/j/Ev",            // a recording
            "https://gowustl-my.sharepoint.com/:i:/g/personal/j/Ei",            // an image
            "https://wustl.sharepoint.com/sites/HR/SitePages/Home.aspx",        // an intranet page
            "https://wustl.sharepoint.com/",
            "https://wustl.sharepoint.com/sites/lab/_layouts/15/Doc.aspx?file=Budget.xlsx",
            "https://wustl.sharepoint.com/sites/lab/_layouts/15/stream.aspx?id=x",
            "https://1drv.ms/x/s!AbCdEf", "https://1drv.ms/",
            "https://onedrive.live.com/about/en-us/",
            "https://www.box.com/pricing", "https://drive.google.com/", "https://docs.google.com/spreadsheets/d/1/edit",
            "https://docs.google.com/forms/d/e/1/viewform", "https://www.dropbox.com/home", "https://www.icloud.com/numbers/0ab",
            "https://www.dropbox.com/scl/fi/abc/data.xlsx?rlkey=1", "https://example.com/s/file.docx",
            "https://www.biorxiv.org/content/10.1101/2026.09.20.612345v1",
        ] {
            #expect(m(url) == nil, "\(url)")
        }
    }

    @Test func boxGoogleDropboxICloud() {
        #expect(m("https://wustl.app.box.com/s/abc123")?.provider == .box)
        #expect(m("https://wustl.box.com/s/abc123")?.provider == .box)
        #expect(m("https://app.box.com/file/12345")?.provider == .box)
        #expect(m("https://drive.google.com/file/d/1AbC/view?usp=sharing")?.provider == .googleDrive)
        #expect(m("https://drive.google.com/drive/folders/1AbC")?.provider == .googleDrive)
        #expect(m("https://drive.google.com/open?id=1AbC")?.provider == .googleDrive)
        #expect(m("https://docs.google.com/document/d/1AbC/edit")?.provider == .googleDocs)
        #expect(m("https://docs.google.com/presentation/d/1AbC/edit")?.provider == .googleDocs)
        #expect(m("https://www.dropbox.com/scl/fi/abc/Draft%20v2.docx?rlkey=k&dl=0")
                == .init(provider: .dropbox, documentKind: "docx", fileName: "Draft v2.docx"))
        #expect(m("https://www.dropbox.com/s/abc/paper.pdf?dl=0")?.documentKind == "pdf")
        #expect(m("https://www.icloud.com/iclouddrive/0abc#Draft")?.provider == .icloud)
        #expect(m("https://www.icloud.com/keynote/0abc#Talk")?.provider == .icloud)
    }

    @Test func aSafeLinksWrappedSharePointLinkBecomesAShareRow() throws {
        let target = DocKit.sharepointLinks[0]
        let wrapped = try #require(URL(string: DocKit.safeLink(target)))
        let c = try #require(PaperLinkClassifier.classify(wrapped, anchorText: "Manuscript draft, version three", shareLinks: true))
        #expect(c.origin == .shareLink)
        #expect(c.url == target)
        #expect(c.urlOriginal == wrapped.absoluteString)                     // 打开链接 keeps the click-time scan
        #expect(c.host == "gowustl-my.sharepoint.com")
        #expect(c.shareHost == MailShareProvider.sharepoint.rawValue)
        #expect(c.documentKind == "docx")
        #expect(c.pdfState == .needsPDF)
        #expect(c.title == "Manuscript draft, version three")
        #expect(PaperLinkClassifier.pdfURL(for: c) == nil)
    }

    @Test func proofpointWrappedAndBareLinksToo() throws {
        let pp = "https://urldefense.com/v3/__https://wustl.box.com/s/abc123__;!!K543!abcdef$"
        let c = try #require(PaperLinkClassifier.classify(URL(string: pp)!, anchorText: nil, shareLinks: true))
        #expect(c.origin == .shareLink && c.shareHost == "box.com" && c.url == "https://wustl.box.com/s/abc123")
        #expect(c.title == nil)
        let d = try #require(PaperLinkClassifier.classify(URL(string: "https://www.dropbox.com/scl/fi/x/Lab_draft.docx?dl=0")!,
                                                          anchorText: nil, shareLinks: true))
        #expect(d.title == "Lab draft")                                      // from the file name in the URL
    }

    /// Without `shareLinks` (alert mail) the classifier behaves as before, and a share-service
    /// URL is never downloadable either way.
    @Test func alertMailKeepsTheOldBehaviourAndNothingDownloads() throws {
        let b = try #require(PaperLinkClassifier.classify(URL(string: "https://wustl-my.sharepoint.com/:b:/g/personal/x/EAbc?e=1")!,
                                                          anchorText: nil))
        #expect(b.origin == .link && b.pdfState == .needsPDF)
        let pdf = try #require(PaperLinkClassifier.classify(URL(string: "https://www.dropbox.com/s/abc/paper.pdf?dl=1")!,
                                                            anchorText: "Smith et al. 2026 (PDF)"))
        #expect(pdf.origin == .link)
        #expect(pdf.pdfState == .needsPDF)                                   // never auto-downloaded
        #expect(PaperLinkClassifier.pdfURL(for: pdf) == nil)
        // A non-share PDF link is still downloadable.
        let direct = try #require(PaperLinkClassifier.classify(URL(string: "https://example.org/files/paper.pdf")!, anchorText: nil))
        #expect(direct.pdfState == .downloadable)
    }

    @Test func providerNames() {
        #expect(MailShareProvider.sharepoint.name(.en) == "SharePoint / OneDrive")
        #expect(MailShareProvider.googleDocs.name(.zh) == "Google 文档")
        #expect(MailShareProvider.icloud.name(.zh) == "iCloud 云盘" && MailShareProvider.icloud.name(.en) == "iCloud Drive")
        let row = MailItem(ord: 1, cand: "c1", origin: .shareLink, shareHost: "box.com")
        #expect(MailShareProvider.name(for: row, .en) == "Box")
        #expect(MailShareProvider.of(MailItem(ord: 1, cand: "c1", origin: .link, shareHost: "box.com")) == nil)
        #expect(MailShareProvider.of(MailItem(ord: 1, cand: "c1", origin: .shareLink, shareHost: "nope")) == nil)
        for p in MailShareProvider.allCases { #expect(!p.name(.en).isEmpty && !p.name(.zh).isEmpty) }
    }

    @Test func hintsInBothLanguages() {
        #expect(MailDocumentText.conversionCaveat(.en).contains("Figures"))
        #expect(MailDocumentText.conversionCaveat(.zh).contains("图片"))
        #expect(MailDocumentText.openOnlyHint(.en).contains("PDF") && MailDocumentText.openOnlyHint(.zh).contains("PDF"))
        #expect(MailDocumentText.shareLinkHint(provider: "Box", .en).hasPrefix("Shared on Box"))
        #expect(MailDocumentText.shareLinkHint(provider: nil, .zh).hasPrefix("共享文件"))
    }
}
