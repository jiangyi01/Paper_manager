import Foundation

/// Decides whether a mail link points at a paper and which identifiers it carries
/// (MAIL_DESIGN Part A §2.4). Pure string work — nothing is fetched.
///
/// Recognizes arXiv (and mirrors), bioRxiv/medRxiv `/content/10.1101|10.64898/…`, doi.org,
/// Nature article ids, Cell/ScienceDirect PIIs, `…/doi/10.…` publisher paths (Science, PNAS,
/// Wiley, ACS…), PLOS `?id=`, eLife, PubMed/PMC/Europe PMC, OpenReview, SSRN, Research Square,
/// direct `*.pdf` links, and title-anchored links to known publisher hosts. Newsletter chrome
/// (unsubscribe, manage alerts, view in browser, privacy, social and logo links) is rejected.
package enum PaperLinkClassifier {

    /// A paper candidate (`cand` empty — the extractor numbers them), or nil for non-paper links.
    /// `url` is the unwrapped canonical URL, `urlOriginal` the link as it appeared in the mail.
    /// `shareLinks` (a person's / advisor's / dropped email): a link to a shared file
    /// (`ShareLinks.match`: SharePoint / OneDrive, Box, Google Drive / Docs, Dropbox, iCloud Drive)
    /// is a `shareLink` candidate — `needsPDF`, never downloadable (it needs the user's sign-in).
    package static func classify(_ url: URL, anchorText: String?, shareLinks: Bool = false) -> MailCandidate? {
        let u = LinkUnwrapper.unwrap(url)
        guard let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = u.host?.lowercased(), !rawHost.isEmpty else { return nil }
        let anchor = anchorText.map(HTMLText.collapse)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDenied(u, anchorText: anchor) else { return nil }
        if shareLinks, let share = ShareLinks.match(u) {
            return shareCandidate(share, unwrapped: u, original: url, anchor: anchor)
        }

        let host = displayHost(rawHost)
        let path = u.path
        var ids = PaperIDs()
        var paperPage = false

        if let a = arxiv(u) {
            ids.arxivID = a.id; ids.arxivVersion = a.version
        } else if let d = doiFromURL(u, host: host) {
            if let a = MetadataClients.arxivID(fromDOI: d) { ids.arxivID = a } else { ids.doi = d }
        } else if let pii = pii(u, host: host) {
            ids.pii = pii
        }

        let lowerPath = path.lowercased()
        let direct = lowerPath.hasSuffix(".pdf") || u.lastPathComponent.lowercased() == "pdf"
        if direct, ids.isEmpty {
            ids = Identifiers.detect(fileName: u.lastPathComponent, firstPagesText: "", attributeTitle: nil, xmpHead: nil)
        }
        if pubmedID(from: u) != nil || pmcID(from: u) != nil || isEuropePMC(u, host: host) || isOpenReview(u, host: host) {
            paperPage = true
        }
        if isFileShare(host), (anchor ?? "").lowercased().contains("pdf") || u.absoluteString.lowercased().contains("pdf")
            || u.absoluteString.contains(":b:") {
            paperPage = true
        }
        let title = anchor.flatMap { isTitleLike($0) ? $0 : nil }
        if ids.isEmpty, !direct, !paperPage {
            guard isPaperHost(host), title != nil, !isNonArticlePath(lowerPath) else { return nil }
        }

        var c = MailCandidate(cand: "", origin: .link, title: title, ids: ids, url: u.absoluteString,
                              urlOriginal: url.absoluteString, host: host)
        if title == nil, let a = anchor, !a.isEmpty, !HTMLText.looksLikeURL(a) { c.snippet = String(a.prefix(200)) }
        c.pdfState = pdfURL(for: c) != nil ? .downloadable : .needsPDF
        return c
    }

    /// A `shareLink` candidate: title from a title-like anchor, else the file name the URL carries.
    private static func shareCandidate(_ share: ShareLinks.Match, unwrapped u: URL, original: URL,
                                       anchor: String?) -> MailCandidate {
        var title = anchor.flatMap { isTitleLike($0) ? $0 : nil }
        if title == nil, let name = share.fileName { title = MailExtractor.documentTitle(name) }
        var c = MailCandidate(cand: "", origin: .shareLink, title: title, url: u.absoluteString,
                              urlOriginal: original.absoluteString, host: displayHost(u.host ?? ""),
                              pdfState: .needsPDF, documentKind: share.documentKind, shareHost: share.provider.rawValue)
        if let a = anchor, !a.isEmpty, !HTMLText.looksLikeURL(a), a != title { c.snippet = String(a.prefix(200)) }
        return c
    }

    // MARK: - PDF availability

    /// A direct PDF URL the downloader may try: arXiv, direct `.pdf`/`/pdf` links, bioRxiv/medRxiv
    /// full-text PDFs (try once — Cloudflare often blocks them). Nil for landing pages.
    package static func pdfURL(for candidate: MailCandidate) -> URL? {
        // A shared file needs the user's sign-in, an attached document is no PDF: never downloaded.
        if candidate.origin == .shareLink || candidate.origin == .document { return nil }
        if let s = candidate.url, let host = URL(string: s)?.host, ShareLinks.isShareService(host) { return nil }
        if let id = candidate.ids.arxivID {
            return URL(string: "https://arxiv.org/pdf/\(id)" + (candidate.ids.arxivVersion.map { "v\($0)" } ?? ""))
        }
        if let s = candidate.url, let u = URL(string: s), let direct = URLImporter.pdfURL(for: u) { return direct }
        if let doi = candidate.ids.doi, let b = preprintDOI(doi) {
            let med = (candidate.host ?? "").contains("medrxiv") || b.range(of: #"\.\d{8}$"#, options: .regularExpression) != nil
            var version = 1
            if let s = candidate.url, let m = s.range(of: #"(?<=\d)v(\d+)(?=[./?#]|$)"#, options: .regularExpression),
               let v = Int(s[m].dropFirst()) { version = v }
            return URL(string: "https://www.\(med ? "medrxiv" : "biorxiv").org/content/\(b)v\(version).full.pdf")
        }
        return nil
    }

    /// bioRxiv / medRxiv DOI without version: 10.1101 or 10.64898 + "YYYY.MM.DD.NNNNNN(NN)"
    /// (medRxiv ids have 8 digits), or a legacy numeric bioRxiv id. Nil for other DOIs.
    package static func preprintDOI(_ doi: String) -> String? {
        if let b = MetadataClients.biorxivDOI(doi) { return b }
        var d = doi.lowercased()
        if let r = d.range(of: #"(?<=\d)v\d+$"#, options: .regularExpression) { d.removeSubrange(r) }
        guard d.range(of: #"^10\.(1101|64898)/\d{4}\.\d{2}\.\d{2}\.\d{6,8}$"#, options: .regularExpression) != nil else { return nil }
        return d
    }

    // MARK: - Identifier recognizers

    /// arXiv abs/pdf/html via `URLImporter.arxivPDF`, plus mirrors (alphaXiv, Hugging Face papers,
    /// ar5iv, Semantic Scholar /arxiv/, SciRate).
    static func arxiv(_ u: URL) -> (id: String, version: Int?)? {
        if let a = URLImporter.arxivPDF(u) {
            return splitVersion(String(a.url.path.dropFirst("/pdf/".count)))
        }
        let host = displayHost(u.host?.lowercased() ?? "")
        let mirrors: [(String, String)] = [("alphaxiv.org", "/abs/"), ("huggingface.co", "/papers/"), ("ar5iv.org", "/abs/"),
                                           ("ar5iv.org", "/html/"), ("semanticscholar.org", "/arxiv/"), ("scirate.com", "/arxiv/")]
        for (h, prefix) in mirrors where host == h && u.path.hasPrefix(prefix) {
            let rest = String(u.path.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let r = splitVersion(rest), Identifiers.isValidArxivID(r.id) { return r }
        }
        return nil
    }

    private static func splitVersion(_ s: String) -> (id: String, version: Int?)? {
        var id = s.hasSuffix(".pdf") ? String(s.dropLast(4)) : s
        var version: Int?
        if let m = id.range(of: #"v(\d+)$"#, options: .regularExpression) {
            version = Int(id[m].dropFirst())
            id.removeSubrange(m)
        }
        return id.isEmpty ? nil : (id, version)
    }

    /// DOI carried by the URL (path or `doi=`/`id=` query), cleaned and lowercased.
    static func doiFromURL(_ u: URL, host: String) -> String? {
        let path = u.path
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        func query(_ n: String) -> String? { comps?.queryItems?.first(where: { $0.name.lowercased() == n })?.value }

        if host == "doi.org" || host == "dx.doi.org" || host == "doi.wiley.com" || host == "hdl.handle.net" {
            return clean(String(path.dropFirst()))
        }
        if host.hasSuffix("biorxiv.org") || host.hasSuffix("medrxiv.org") {
            if let r = path.range(of: #"/content/(10\.\d{4,9}/[^?#]+)"#, options: .regularExpression) {
                var d = String(path[r].dropFirst("/content/".count))
                d = stripPreprintSuffix(d)
                return clean(d)
            }
            // Older/RSS forms: /content/early/2026/09/20/2026.09.20.612345, /cgi/content/short/2026.09.20.612345v1
            if let r = path.range(of: #"\d{4}\.\d{2}\.\d{2}\.\d{6}"#, options: .regularExpression) {
                return "10.1101/" + path[r]
            }
            return nil
        }
        if host == "nature.com" || host.hasSuffix(".nature.com") {
            if let r = path.range(of: #"^/articles/[A-Za-z0-9.\-]+"#, options: .regularExpression) {
                var id = String(path[r].dropFirst("/articles/".count))
                if id.lowercased().hasSuffix(".pdf") { id = String(id.dropLast(4)) }
                guard id.contains(where: \.isNumber) else { return nil }
                return "10.1038/" + id.lowercased()
            }
        }
        if host == "elifesciences.org" || host.hasSuffix(".elifesciences.org"),
           let r = path.range(of: #"^/(articles|reviewed-preprints)/\d{4,7}"#, options: .regularExpression) {
            let n = path[r].split(separator: "/").last.map(String.init) ?? ""
            return "10.7554/elife." + n
        }
        if host.hasSuffix("ssrn.com"), let id = query("abstract_id") ?? query("abstractid"), id.allSatisfy(\.isNumber) {
            return "10.2139/ssrn." + id
        }
        if host.hasSuffix("researchsquare.com"),
           let r = path.range(of: #"/article/rs-\d+/v\d+"#, options: .regularExpression) {
            return "10.21203/rs.3." + path[r].dropFirst("/article/".count).lowercased()
        }
        for name in ["doi", "id", "rft_id", "article"] {
            if let v = query(name), let d = clean(v.replacingOccurrences(of: "info:doi/", with: "")) { return d }
        }
        // Generic: a DOI inside the path (/doi/10.…, /article/10.…, /articles/10.…/full).
        if let r = path.range(of: #"10\.\d{4,9}/[^?#\s]+"#, options: .regularExpression) {
            var d = String(path[r])
            let tails = ["/full", "/abstract", "/abs", "/pdf", "/epdf", "/fulltext", "/figures", "/references",
                         "/meta", "/html", "/summary", "/reader", "/view", "/suppl", "/supplementary", "/metrics",
                         "/citedby", "/info", "/pdfft", "/epub", "/download"]
            var changed = true
            while changed {
                changed = false
                for t in tails where d.lowercased().hasSuffix(t) {
                    d = String(d.dropLast(t.count)); changed = true
                }
                if d.hasSuffix("/") { d.removeLast(); changed = true }
            }
            if d.lowercased().hasSuffix(".pdf") { d = String(d.dropLast(4)) }
            if d.hasPrefix("10.1101/") || d.hasPrefix("10.64898/") { d = stripPreprintSuffix(d) }
            return clean(d)
        }
        return nil
    }

    /// "10.1101/2026.02.27.708412v2.full.pdf+html" → "10.1101/2026.02.27.708412".
    private static func stripPreprintSuffix(_ d: String) -> String {
        var s = d
        for suffix in ["+html", ".full.pdf", ".full-text", ".full", ".abstract", ".supplementary-material", ".article-info",
                       ".article-metrics", ".pdf"] where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        if let r = s.range(of: #"(?<=\d)v\d+$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let slash = s.range(of: "/", options: .backwards), s[slash.upperBound...].isEmpty { s.removeLast() }
        return s
    }

    private static func clean(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        guard decoded.hasPrefix("10.") else { return nil }
        return Identifiers.cleanDOI(decoded)
    }

    /// Elsevier PII from Cell Press and ScienceDirect URLs ("S0092-8674(24)01332-1" → "S0092867424013321").
    static func pii(_ u: URL, host: String) -> String? {
        let elsevier = host == "cell.com" || host.hasSuffix(".cell.com") || host.hasSuffix("sciencedirect.com")
            || host == "linkinghub.elsevier.com" || host.hasSuffix("thelancet.com") || host.hasSuffix(".elsevier.com")
        guard elsevier else { return nil }
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        var candidates: [String] = []
        if let q = comps?.queryItems?.first(where: { $0.name.lowercased() == "pii" })?.value { candidates.append(q) }
        let path = u.path
        if let r = path.range(of: #"(?i)/(?:pii|fulltext|abstract|pdf|retrieve/pii|pdfExtended)/(S[0-9X()\-]{15,30})"#,
                              options: .regularExpression) {
            candidates.append(String(path[r].split(separator: "/").last ?? ""))
        }
        for raw in candidates {
            var s = raw.uppercased().filter { $0.isNumber || $0 == "S" || $0 == "X" }
            if s.hasSuffix(".PDF") { s = String(s.dropLast(4)) }
            if s.range(of: #"^S\d{15,16}[\dX]$"#, options: .regularExpression) != nil { return s }
        }
        return nil
    }

    /// PubMed id from pubmed.ncbi.nlm.nih.gov/<pmid>/ or ncbi.nlm.nih.gov/pubmed/<pmid>.
    package static func pubmedID(from u: URL) -> String? {
        let host = displayHost(u.host?.lowercased() ?? "")
        let path = u.path
        if host == "pubmed.ncbi.nlm.nih.gov", let r = path.range(of: #"^/\d{5,9}"#, options: .regularExpression) {
            return String(path[r].dropFirst())
        }
        if host == "ncbi.nlm.nih.gov", let r = path.range(of: #"^/pubmed/\d{5,9}"#, options: .regularExpression) {
            return String(path[r].dropFirst("/pubmed/".count))
        }
        if host == "europepmc.org", let r = path.range(of: #"/(article|abstract)/MED/\d{5,9}"#, options: .regularExpression) {
            return String(path[r].split(separator: "/").last ?? "")
        }
        return nil
    }

    /// PMC id ("PMC1234567") from ncbi.nlm.nih.gov/pmc/articles/… or pmc.ncbi.nlm.nih.gov/articles/….
    package static func pmcID(from u: URL) -> String? {
        let host = displayHost(u.host?.lowercased() ?? "")
        guard host == "ncbi.nlm.nih.gov" || host == "pmc.ncbi.nlm.nih.gov" || host == "europepmc.org" else { return nil }
        guard let r = u.path.range(of: #"(?i)PMC\d{4,9}"#, options: .regularExpression) else { return nil }
        return u.path[r].uppercased()
    }

    private static func isEuropePMC(_ u: URL, host: String) -> Bool {
        host == "europepmc.org" && u.path.range(of: #"^/(article|abstract)/"#, options: .regularExpression) != nil
    }

    private static func isOpenReview(_ u: URL, host: String) -> Bool {
        guard host == "openreview.net", u.path == "/forum" || u.path == "/pdf" else { return false }
        return URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "id" } == true
    }

    // MARK: - Deny list

    private static let deniedHosts = [
        "twitter.com", "x.com", "t.co", "facebook.com", "fb.com", "fb.me", "linkedin.com", "lnkd.in", "instagram.com",
        "youtube.com", "youtu.be", "bsky.app", "threads.net", "weibo.com", "weixin.qq.com", "reddit.com", "tiktok.com",
        "pinterest.com", "whatsapp.com", "wa.me", "t.me", "telegram.me", "mastodon.social", "apps.apple.com",
        "itunes.apple.com", "play.google.com", "gstatic.com", "googleusercontent.com", "doubleclick.net",
        "list-manage.com", "mailchi.mp", "campaign-archive.com", "zoom.us", "teams.microsoft.com", "meet.google.com",
        "calendar.google.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com", "aka.ms",
        "bit.ly", "tinyurl.com", "ow.ly", "buff.ly", "goo.gl", "rb.gy", "shorturl.at", "scholar.google.com",
        "google.com", "gravatar.com", "addthis.com", "sharethis.com", "safelinks.protection.outlook.com",
        "urldefense.com", "urldefense.proofpoint.com",
    ]
    private static let deniedPathParts = [
        "unsubscribe", "/unsub", "/optout", "opt-out", "opt_out", "/preferences", "email-preferences",
        "emailpreferences", "manage-alerts", "managealerts", "/alerts/manage", "alertsettings", "/privacy", "/legal",
        "/terms", "/cookie", "view_op=list_alerts", "update_op=", "cancel_alert", "alert_cancel", "/login", "/signin",
        "/sign-in", "/register", "/subscribe", "/logout", "email_library_add", "/share?", "/sharer",
    ]
    private static let deniedAnchorExact: Set<String> = [
        "terms", "help", "faq", "contact", "contact us", "sign in", "log in", "login", "register", "subscribe",
        "follow us", "twitter", "facebook", "linkedin", "instagram", "youtube", "save", "share", "tweet", "email",
        "print", "rss", "home", "logo", "advertisement", "advertise", "careers", "jobs", "x", "bluesky", "wechat",
        "weibo", "帮助", "联系我们", "订阅", "分享",
    ]
    private static let deniedAnchorParts = [
        "unsubscribe", "manage alert", "manage your alert", "manage subscription", "manage your subscription",
        "email preferences", "update your preferences", "update preferences", "view in browser", "view in your browser",
        "view online", "view this email", "view as a web page", "view as web page", "web version", "privacy",
        "cancel alert", "cancel this alert", "edit alert", "edit this alert", "delete alert", "list alerts",
        "forward to a friend", "terms of use", "terms and conditions", "cookie", "退订", "取消订阅", "隐私",
        "在浏览器中", "管理提醒", "取消提醒", "网页版查看",
    ]

    /// Newsletter chrome, social/logo/meeting links and non-http(s) schemes.
    package static func isDenied(_ u: URL, anchorText: String?) -> Bool {
        guard let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
        let host = displayHost(u.host?.lowercased() ?? "")
        if !isFileShare(host) {
            if deniedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
            if host.hasPrefix("scholar.google.") || LinkUnwrapper.isGoogleHost(host) { return true }
        }
        let lowerPath = u.path.lowercased()
        for ext in [".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".bmp", ".css", ".js"] where lowerPath.hasSuffix(ext) {
            return true
        }
        let full = (u.path + "?" + (u.query ?? "")).lowercased()
        if deniedPathParts.contains(where: { full.contains($0) }) { return true }
        if let a = anchorText?.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)),
           !a.isEmpty {
            if deniedAnchorExact.contains(a) { return true }
            if deniedAnchorParts.contains(where: { a.contains($0) }) { return true }
        }
        return false
    }

    // MARK: - Hosts and titles

    /// Publisher / repository hosts whose article links carry DOIs (or are papers when anchored
    /// by a title). Subdomains match.
    package static let paperHosts: [String] = [
        "nature.com", "cell.com", "sciencedirect.com", "elsevier.com", "science.org", "sciencemag.org", "pnas.org",
        "plos.org", "elifesciences.org", "biorxiv.org", "medrxiv.org", "arxiv.org", "doi.org", "springer.com",
        "springernature.com", "biomedcentral.com", "wiley.com", "tandfonline.com", "sagepub.com", "oup.com",
        "jamanetwork.com", "nejm.org", "thelancet.com", "bmj.com", "frontiersin.org", "mdpi.com", "embopress.org",
        "rupress.org", "jneurosci.org", "cshlp.org", "researchsquare.com", "ssrn.com", "openreview.net", "neurips.cc",
        "mlr.press", "aclanthology.org", "ieee.org", "acm.org", "acs.org", "rsc.org", "iop.org", "aps.org",
        "annualreviews.org", "jci.org", "ncbi.nlm.nih.gov", "europepmc.org", "semanticscholar.org", "lww.com",
        "karger.com", "thieme-connect.com", "degruyter.com", "cambridge.org", "royalsocietypublishing.org",
        "physiology.org", "ahajournals.org", "aacrjournals.org", "ashpublications.org", "jimmunol.org", "asm.org",
        "peerj.com", "f1000research.com", "life-science-alliance.org", "biologists.com", "portlandpress.com",
        "jbc.org", "chemrxiv.org", "osf.io", "preprints.org", "alphaxiv.org", "huggingface.co", "cvf.com",
        "thecvf.com", "aaai.org", "ijcai.org", "jmlr.org", "genetics.org", "academic.oup.com", "embo.org",
        "cellpress.com", "wellcomeopenresearch.org", "gigasciencejournal.com", "genomebiology.biomedcentral.com",
    ]

    package static func isPaperHost(_ host: String) -> Bool {
        let h = displayHost(host)
        return paperHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    private static let fileShareHosts = ["drive.google.com", "docs.google.com", "dropbox.com", "box.com", "1drv.ms",
                                         "onedrive.live.com", "sharepoint.com", "icloud.com"]
    static func isFileShare(_ host: String) -> Bool {
        fileShareHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let nonArticleParts = [
        "/issues", "/volumes", "/toc/", "/current", "/latest", "/subjects", "/collections", "/search", "/about",
        "/authors", "/browse", "/topics", "/podcast", "/jobs", "/events", "/news", "/alerts", "/my-account", "/help",
        "/contact", "/sitemap", "/careers", "/shop", "/subscribe", "/briefing", "/nature-briefing", "/for-authors",
        "/submit", "/advertising", "/webinars", "/blog",
    ]
    private static func isNonArticlePath(_ lowerPath: String) -> Bool {
        lowerPath == "/" || lowerPath.isEmpty || nonArticleParts.contains { lowerPath.contains($0) }
    }

    /// Lowercased host without a leading "www.".
    package static func displayHost(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private static let genericAnchors: Set<String> = [
        "read more", "read the paper", "full text", "full-text", "download pdf", "view article", "view abstract",
        "click here", "read article", "read full article", "view full text", "view pdf", "open access",
        "read the full article", "view the full article", "access the full text", "download the pdf",
        "view this article online", "read the full paper", "click here to read", "read the full story",
        "continue reading", "see all results", "see more results", "view all", "view all articles", "read online",
        "full text (html)", "full text (pdf)", "download full text", "download article", "view in browser",
    ]

    /// Anchor text that can serve as a paper title (15–300 chars and ≥ 3 words, or ≥ 6 CJK chars,
    /// not a URL or a generic "Read more" phrase).
    package static func isTitleLike(_ raw: String) -> Bool {
        let s = HTMLText.collapse(raw)
        let cjk = s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        guard s.count <= 300, s.count >= (cjk >= 6 ? 6 : 15), !HTMLText.looksLikeURL(s) else { return false }
        let lower = s.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if genericAnchors.contains(lower) { return false }
        if lower.hasPrefix("doi:") || lower.hasPrefix("10.") || lower.hasPrefix("arxiv:") { return false }
        let words = s.split(whereSeparator: { $0 == " " }).filter { $0.contains(where: \.isLetter) }.count
        return words >= 3 || cjk >= 6
    }
}
