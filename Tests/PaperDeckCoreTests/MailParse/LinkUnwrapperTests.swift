import Foundation
import Testing
@testable import PaperDeckCore

@Suite("MailParse · LinkUnwrapper") struct MailParseLinkUnwrapperTests {

    private static func unwrap(_ s: String) -> String {
        LinkUnwrapper.unwrap(URL(string: s)!).absoluteString
    }

    private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }

    @Test func safeLinks() {
        let wrapped = "https://nam02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.nature.com%2Farticles%2Fs41593-026-01999-8%3Futm_source%3Dnature_etoc%26utm_medium%3Demail&data=05%7C02%7Cyi.jiang%40wustl.edu%7C0f1e&sdata=AbCd%3D&reserved=0"
        #expect(Self.unwrap(wrapped) == "https://www.nature.com/articles/s41593-026-01999-8")
        #expect(Self.unwrap("https://gcc02.safelinks.protection.outlook.com/?url=https%3A%2F%2Farxiv.org%2Fabs%2F2609.12345&data=x")
                == "https://arxiv.org/abs/2609.12345")
    }

    @Test func proofpointV2() {
        let v2 = "https://urldefense.proofpoint.com/v2/url?u=https-3A__www.biorxiv.org_content_10.1101_2026.09.14.612345v2-3Futm-5Fsource-3Dx&d=DwMFaQ&c=abc&r=def&m=ghi&s=jkl&e="
        #expect(Self.unwrap(v2) == "https://www.biorxiv.org/content/10.1101/2026.09.14.612345v2")
    }

    @Test func proofpointV3() {
        let single = "https://urldefense.com/v3/__https://www.cell.com/cell/fulltext/S0092-8674(26)00123-4?src=alert*utm_source=etoc__;Jg!!AbCdEfGh!IjKlMnOp-QrStUv$"
        #expect(Self.unwrap(single) == "https://www.cell.com/cell/fulltext/S0092-8674(26)00123-4?src=alert")
        let run = "https://urldefense.com/v3/__https://example.org/p?x=1**Ay=2__;JiY!!Tenant!Sig$"
        #expect(Self.unwrap(run) == "https://example.org/p?x=1&&y=2")
        let none = "https://urldefense.com/v3/__https://doi.org/10.1038/s41586-026-01234-5__;!!Tenant!Sig$"
        #expect(Self.unwrap(none) == "https://doi.org/10.1038/s41586-026-01234-5")
    }

    @Test func googleRedirects() {
        #expect(Self.unwrap("https://scholar.google.com/scholar_url?url=https://arxiv.org/abs/2609.12345&hl=en&sa=X&scisig=AAZ&oi=scholaralrt")
                == "https://arxiv.org/abs/2609.12345")
        #expect(Self.unwrap("https://scholar.google.de/scholar_url?url=https://www.nature.com/articles/s41586-026-01234-5&hl=de")
                == "https://www.nature.com/articles/s41586-026-01234-5")
        #expect(Self.unwrap("https://www.google.com/url?q=https://www.pnas.org/doi/10.1073/pnas.2400001121&sa=D&ust=1&usg=AOv")
                == "https://www.pnas.org/doi/10.1073/pnas.2400001121")
        #expect(Self.unwrap("https://www.google.co.uk/url?url=https%3A%2F%2Felifesciences.org%2Farticles%2F98765")
                == "https://elifesciences.org/articles/98765")
        // Scholar pages that are not redirects stay as they are.
        #expect(Self.unwrap("https://scholar.google.com/scholar_alerts?view_op=list_alerts") == "https://scholar.google.com/scholar_alerts?view_op=list_alerts")
    }

    @Test func nestedWrappers() {
        let scholar = "https://scholar.google.com/scholar_url?url=https://www.nature.com/articles/s41586-026-01234-5%3Futm_source%3Dscholar&hl=en"
        // Proofpoint v3 around Scholar ("&" replaced by "*"), then Safe Links around Proofpoint.
        let v3 = "https://urldefense.com/v3/__" + scholar.replacingOccurrences(of: "&", with: "*") + "__;Jg!!T!S$"
        let safe = "https://nam02.safelinks.protection.outlook.com/?url=" + Self.percent(v3) + "&data=05%7C02&reserved=0"
        #expect(Self.unwrap(safe) == "https://www.nature.com/articles/s41586-026-01234-5")
    }

    @Test func sesClickTracking() {
        let ses = "https://click.notification.elsevier.com/CL0/https:%2F%2Fwww.cell.com%2Fcell%2Ffulltext%2FS0092-8674(26)00200-1%3Fdgcid%3Detoc/1/0100019a2b3c-abc/AbCdEf=380"
        #expect(Self.unwrap(ses) == "https://www.cell.com/cell/fulltext/S0092-8674(26)00200-1")
    }

    @Test func trackingParameters() {
        #expect(Self.unwrap("https://www.biorxiv.org/content/10.1101/x?utm_source=a&utm_campaign=b&fbclid=c&mc_eid=d&rss=1")
                == "https://www.biorxiv.org/content/10.1101/x")
        #expect(Self.unwrap("https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0301234&utm_medium=email&page=2")
                == "https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0301234&page=2")
        #expect(Self.unwrap("https://www.nature.com/articles/s41586-026-01234-5?error=cookies_not_supported&code=abc")
                == "https://www.nature.com/articles/s41586-026-01234-5")
        #expect(Self.unwrap("https://openreview.net/forum?id=AbC123&code=keep") == "https://openreview.net/forum?id=AbC123&code=keep")
        #expect(Self.unwrap("https://example.org/p?elqTrackId=1&WT.mc_id=2&keep=3") == "https://example.org/p?keep=3")
    }

    @Test func neverUnwrapsToUnsafeSchemes() {
        let js = "https://nam02.safelinks.protection.outlook.com/?url=" + Self.percent("javascript:alert(1)") + "&data=x"
        let out = Self.unwrap(js)
        #expect(out.hasPrefix("https://nam02.safelinks.protection.outlook.com/"))
        #expect(PaperLinkClassifier.classify(URL(string: js)!, anchorText: "Read the full paper now please") == nil)
        let data = "https://www.google.com/url?q=" + Self.percent("data:text/html,<script>x</script>")
        #expect(Self.unwrap(data).hasPrefix("https://www.google.com/url"))
    }

    @Test func shareLinksAndPlainLinksStay() {
        let share = "https://twitter.com/intent/tweet?url=https://doi.org/10.1038/x&text=wow"
        #expect(Self.unwrap(share) == share)
        #expect(Self.unwrap("https://www.nature.com/articles/s41586-026-01234-5") == "https://www.nature.com/articles/s41586-026-01234-5")
        // A generic redirector carrying a full URL is unwrapped.
        #expect(Self.unwrap("https://links.example-mailer.com/track?url=https%3A%2F%2Farxiv.org%2Fabs%2F2609.12345&id=9")
                == "https://arxiv.org/abs/2609.12345")
    }

    @Test func lenientURLParsing() {
        #expect(LinkUnwrapper.url(from: " www.nature.com/articles/x ")?.absoluteString == "https://www.nature.com/articles/x")
        #expect(LinkUnwrapper.url(from: "https://example.org/a b")?.absoluteString == "https://example.org/a%20b")
        #expect(LinkUnwrapper.url(from: "") == nil)
    }
}
