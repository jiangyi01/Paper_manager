import Foundation

/// Parsers for alert / table-of-contents mail (MAIL_DESIGN Part A §2.5). Each entry becomes an
/// `.alertEntry` candidate (cand empty — the extractor numbers them) with title, authors, the
/// link's identifiers and a snippet. Pure; the HTML is tokenized, never rendered.
///
/// - Google Scholar: `a.gse_alrt_title` (title + link), the following author line
///   ("A Author, B Author - Venue, 2026"), `div.gse_alrt_sni` (snippet).
/// - arXiv mailing lists: plain-text `arXiv:ID` / `Title:` / `Authors:` blocks.
/// - bioRxiv / medRxiv alerts: title anchors to `/content/10.…`, then the author line.
/// - Generic TOC (`generic: true`): anchors with 20–300 characters of title-like text that point
///   at DOI-bearing hosts.
package enum AlertParsers {

    /// All entries found in a message, de-duplicated by identifiers / URL, in document order.
    package static func parse(html: String?, plainText: String?, generic: Bool) -> [MailCandidate] {
        var out: [MailCandidate] = []
        if let html, !html.isEmpty {
            if html.contains("gse_alrt_title") {
                out += googleScholar(html: html)
            } else {
                out += biorxiv(html: html)
            }
        }
        let text = plainText ?? html.map(HTMLText.text) ?? ""
        if text.contains("Title:"), text.range(of: #"(?m)^\s*arXiv:\s*\S"#, options: .regularExpression) != nil {
            out += arxivListing(text: text)
        }
        if generic, out.isEmpty, let html { out += genericTOC(html: html) }
        return dedupe(out)
    }

    // MARK: - Google Scholar

    package static func googleScholar(html: String) -> [MailCandidate] {
        let doc = Document(html)
        let titles = doc.anchors.indices.filter { doc.anchors[$0].classes.contains("gse_alrt_title") }
        var out: [MailCandidate] = []
        for (n, ai) in titles.enumerated() {
            let titleRuns = doc.runs.indices.filter { doc.runs[$0].anchor == ai }
            guard let last = titleRuns.last else { continue }
            let title = doc.anchors[ai].text
            guard !title.isEmpty else { continue }
            let nextStart = n + 1 < titles.count
                ? (doc.runs.firstIndex(where: { $0.anchor == titles[n + 1] }) ?? doc.runs.count) : doc.runs.count
            let tail = last + 1 < nextStart ? Array(doc.runs[(last + 1)..<nextStart]) : []

            var authorLine: String?
            var snippetParts: [String] = []
            for block in groupByBlock(tail) {
                let text = HTMLText.collapse(block.runs.filter { $0.anchor == nil }.map(\.text).joined(separator: " "))
                guard !text.isEmpty else { continue }
                if block.cls.contains("gse_alrt_sni") { snippetParts.append(text); continue }
                if authorLine == nil, snippetParts.isEmpty, text != "[PDF]", text != "[HTML]" { authorLine = text }
            }
            let byline: (authors: [String], venue: String?, year: Int?) = authorLine.map(parseScholarByline) ?? ([], nil, nil)
            var c = entry(title: title, href: doc.anchors[ai].href, authors: byline.authors)
            c.venue = byline.venue
            c.year = byline.year
            if c.ids.isEmpty, let a = authorLine.flatMap(arxivIDInText) { c.ids.arxivID = a; c.pdfState = .downloadable }
            let snippet = HTMLText.collapse(snippetParts.joined(separator: " "))
            if !snippet.isEmpty { c.snippet = String(snippet.prefix(400)) }
            out.append(c)
        }
        return out
    }

    /// "A Smith, B Jones… - Nature Neuroscience, 2026 - nature.com" → authors, venue, year.
    static func parseScholarByline(_ line: String) -> (authors: [String], venue: String?, year: Int?) {
        let parts = line.components(separatedBy: " - ").flatMap { $0.components(separatedBy: " – ") }
        let authors = (parts.first ?? "").replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 80 }
        var venue: String?
        var year: Int?
        if parts.count > 1 {
            var v = parts[1].trimmingCharacters(in: .whitespaces)
            if let r = v.range(of: #",?\s*((19|20)\d{2})\s*$"#, options: .regularExpression) {
                year = Int(v[r].filter(\.isNumber))
                v.removeSubrange(r)
            }
            v = v.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { venue = v }
        }
        return (Array(authors.prefix(50)), venue, year)
    }

    // MARK: - arXiv listing

    private static let arxivHeader = try! NSRegularExpression(
        pattern: #"^\s*arXiv:\s*(\d{4}\.\d{4,5}|[a-z\-]+(?:\.[A-Z]{2})?/\d{7})(v\d+)?\b"#)

    package static func arxivListing(text: String) -> [MailCandidate] {
        let lines = text.components(separatedBy: "\n")
        var out: [MailCandidate] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let ns = line as NSString
            guard let m = arxivHeader.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { i += 1; continue }
            let id = ns.substring(with: m.range(at: 1))
            let version = m.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 2)).dropFirst())
            guard id.contains("/") || Identifiers.isValidArxivID(id) else { i += 1; continue }

            // Fields until the entry's separator line.
            var fields: [String: String] = [:]
            var lastField: String?
            var abstract: [String] = []
            var slashes = 0
            var j = i + 1
            while j < lines.count {
                let l = lines[j]
                let t = l.trimmingCharacters(in: .whitespaces)
                if arxivHeader.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil { break }
                if t.hasPrefix("-----") && t.count >= 20 { j += 1; break }
                if t.hasPrefix("\\\\") {
                    slashes += 1
                    if slashes >= 2 { j += 1; break }
                    lastField = nil
                    j += 1
                    continue
                }
                if slashes == 1 {
                    if !t.isEmpty { abstract.append(t) }
                } else if let colon = t.firstIndex(of: ":"), l.first.map({ !$0.isWhitespace }) == true,
                          t[..<colon].allSatisfy({ $0.isLetter || $0 == "-" }), t.distance(from: t.startIndex, to: colon) <= 16 {
                    let key = t[..<colon].lowercased()
                    fields[key] = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    lastField = key
                } else if let k = lastField, !t.isEmpty, l.first?.isWhitespace == true {
                    fields[k, default: ""] += " " + t
                }
                j += 1
            }
            if let title = fields["title"].map(HTMLText.collapse), !title.isEmpty {
                var c = MailCandidate(cand: "", origin: .alertEntry, title: title,
                                      authors: splitAuthors(fields["authors"] ?? ""),
                                      ids: PaperIDs(arxivID: id, arxivVersion: version),
                                      url: "https://arxiv.org/abs/\(id)", urlOriginal: nil, host: "arxiv.org")
                c.pdfState = .downloadable
                let abs = HTMLText.collapse(abstract.joined(separator: " "))
                if !abs.isEmpty { c.snippet = String(abs.prefix(400)) }
                out.append(c)
            }
            i = max(j, i + 1)
        }
        return out
    }

    /// "A. Smith (MIT), B. Jones and C. Wang" → ["A. Smith", "B. Jones", "C. Wang"].
    static func splitAuthors(_ raw: String) -> [String] {
        var s = raw
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") { s.removeSubrange(open...close) }
        s = s.replacingOccurrences(of: " and ", with: ", ").replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "、", with: ",").replacingOccurrences(of: "，", with: ",")
        return Array(s.split(separator: ",").map { HTMLText.collapse(String($0)) }
            .filter { !$0.isEmpty && $0.lowercased() != "et al." && $0.lowercased() != "et al" && $0.count <= 80 }
            .prefix(50))
    }

    // MARK: - bioRxiv / medRxiv

    package static func biorxiv(html: String) -> [MailCandidate] {
        titleAnchorEntries(Document(html)) { c in
            let h = c.host ?? ""
            return (h.hasSuffix("biorxiv.org") || h.hasSuffix("medrxiv.org")) && c.ids.doi != nil
        }
    }

    // MARK: - Generic TOC

    package static func genericTOC(html: String) -> [MailCandidate] {
        titleAnchorEntries(Document(html)) { c in
            !c.ids.isEmpty || PaperLinkClassifier.isPaperHost(c.host ?? "")
        }
    }

    /// Title-anchored links accepted by `accept`, with the author line that follows them.
    private static func titleAnchorEntries(_ doc: Document, accept: (MailCandidate) -> Bool) -> [MailCandidate] {
        var out: [MailCandidate] = []
        for (ai, a) in doc.anchors.enumerated() {
            let title = a.text
            guard (20...300).contains(title.count), PaperLinkClassifier.isTitleLike(title),
                  let url = LinkUnwrapper.url(from: a.href),
                  let classified = PaperLinkClassifier.classify(url, anchorText: title), accept(classified) else { continue }
            var c = classified
            c.origin = .alertEntry
            c.title = title
            c.snippet = nil
            // Author line / snippet: the next non-anchor blocks after the title anchor.
            guard let last = doc.runs.lastIndex(where: { $0.anchor == ai }) else { out.append(c); continue }
            let stop = doc.runs[(last + 1)...].firstIndex(where: { r in
                r.anchor.map { doc.anchors[$0].text.count >= 20 } ?? false
            }) ?? doc.runs.count
            var blocks = groupByBlock(Array(doc.runs[(last + 1)..<stop])).map {
                HTMLText.collapse($0.runs.filter { $0.anchor == nil }.map(\.text).joined(separator: " "))
            }.filter { !$0.isEmpty }
            if let first = blocks.first, looksLikeAuthorLine(first) {
                c.authors = splitAuthors(first)
                blocks.removeFirst()
            }
            if let snip = blocks.prefix(3).first(where: isSnippet) { c.snippet = String(snip.prefix(400)) }
            out.append(c)
        }
        return out
    }

    /// An abstract-like block after an entry (not the "bioRxiv 2026…; doi:" line or newsletter footer).
    static func isSnippet(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard s.count >= 60, !lower.hasPrefix("biorxiv"), !lower.hasPrefix("medrxiv"), !lower.contains("doi:") else { return false }
        let footer = ["unsubscribe", "receiving this email", "manage alerts", "manage your alerts", "privacy",
                      "you are receiving", "you received this", "view in browser", "copyright ©"]
        return !footer.contains { lower.contains($0) }
    }

    static func looksLikeAuthorLine(_ s: String) -> Bool {
        guard (3...600).contains(s.count), s.contains(",") || s.contains(" and ") || s.contains("、") else { return false }
        let lower = s.lowercased()
        if lower.hasPrefix("biorxiv") || lower.hasPrefix("medrxiv") || lower.contains("doi") || lower.contains("http") { return false }
        guard s.filter(\.isNumber).count <= 4 else { return false }
        let parts = s.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: "、", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { $0.count <= 50 && $0.split(separator: " ").count <= 6 }
    }

    // MARK: - Shared

    private static func entry(title: String, href: String, authors: [String]) -> MailCandidate {
        guard let url = LinkUnwrapper.url(from: href) else {
            return MailCandidate(cand: "", origin: .alertEntry, title: title, authors: authors, pdfState: .needsPDF)
        }
        if var c = PaperLinkClassifier.classify(url, anchorText: title) {
            c.origin = .alertEntry
            c.title = title
            c.authors = authors
            c.snippet = nil
            return c
        }
        let u = LinkUnwrapper.unwrap(url)
        var c = MailCandidate(cand: "", origin: .alertEntry, title: title, authors: authors, url: u.absoluteString,
                              urlOriginal: url.absoluteString,
                              host: PaperLinkClassifier.displayHost(u.host ?? ""))
        c.pdfState = PaperLinkClassifier.pdfURL(for: c) != nil ? .downloadable : .needsPDF
        return c
    }

    static func arxivIDInText(_ s: String) -> String? {
        guard let r = s.range(of: #"(?i)arXiv:\s*(\d{4}\.\d{4,5})"#, options: .regularExpression) else { return nil }
        let id = String(s[r].drop(while: { !$0.isNumber }))
        return Identifiers.isValidArxivID(id) ? id : nil
    }

    static func dedupe(_ list: [MailCandidate]) -> [MailCandidate] {
        var out: [MailCandidate] = []
        var seen = Set<String>()
        for c in list {
            let keys = MailExtractor.identityKeys(c)
            if !keys.isEmpty, !seen.isDisjoint(with: keys) { continue }
            seen.formUnion(keys)
            out.append(c)
        }
        return out
    }

    // MARK: - Document model (text runs with their anchor and enclosing block)

    struct Run {
        var text: String
        var anchor: Int?
        var block: Int
        var cls: String
    }

    struct Document {
        var runs: [Run] = []
        var anchors: [HTMLText.Anchor] = []

        private static let blocks: Set<String> = [
            "div", "p", "td", "th", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "br", "ul", "ol",
            "blockquote", "section", "article", "header", "footer", "center", "dd", "dt", "hr",
        ]
        private static let dropped: Set<String> = ["head", "script", "style", "title", "template", "svg"]

        init(_ html: String) {
            var stack: [(name: String, cls: String, hidden: Bool, anchor: Int?)] = []
            var hidden = 0
            var block = 0
            var anchorText: [Int: String] = [:]
            for token in HTMLText.tokenize(html) {
                switch token {
                case .start(let name, let attrs, let selfClosing):
                    if Document.blocks.contains(name) { block += 1 }
                    if name == "br" || name == "hr" || name == "img" || name == "meta" || name == "link" || selfClosing { continue }
                    let isHidden = Document.dropped.contains(name) || HTMLText.isHidden(attrs)
                    if isHidden { hidden += 1 }
                    var anchor: Int?
                    if name == "a", hidden == 0 {
                        if let open = stack.lastIndex(where: { $0.name == "a" }) { Document.close(to: open, &stack, &hidden) }
                        anchors.append(HTMLText.Anchor(href: (attrs["href"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                                       text: "", classes: (attrs["class"] ?? "").split(separator: " ").map(String.init)))
                        anchor = anchors.count - 1
                        anchorText[anchor!] = ""
                    }
                    stack.append((name, attrs["class"] ?? "", isHidden, anchor))
                case .end(let name):
                    if Document.blocks.contains(name) { block += 1 }
                    if let idx = stack.lastIndex(where: { $0.name == name }) { Document.close(to: idx, &stack, &hidden) }
                case .text(let t):
                    guard hidden == 0 else { continue }
                    let anchor = stack.last(where: { $0.anchor != nil })?.anchor
                    if let a = anchor { anchorText[a, default: ""] += t }      // raw: keeps inter-tag spaces
                    let text = HTMLText.collapse(t)
                    guard !text.isEmpty else { continue }
                    let cls = stack.last(where: { Document.blocks.contains($0.name) && !$0.cls.isEmpty })?.cls ?? ""
                    runs.append(Run(text: text, anchor: anchor, block: block, cls: cls))
                }
            }
            for (i, t) in anchorText { anchors[i].text = HTMLText.collapse(t) }
        }

        private static func close(to idx: Int, _ stack: inout [(name: String, cls: String, hidden: Bool, anchor: Int?)],
                                  _ hidden: inout Int) {
            while stack.count > idx {
                let el = stack.removeLast()
                if el.hidden { hidden = max(0, hidden - 1) }
            }
        }
    }

    private static func groupByBlock(_ runs: [Run]) -> [(cls: String, runs: [Run])] {
        var out: [(cls: String, runs: [Run])] = []
        var lastBlock: Int?
        for r in runs {
            if r.block == lastBlock, !out.isEmpty { out[out.count - 1].runs.append(r) }
            else { out.append((r.cls, [r])); lastBlock = r.block }
        }
        return out
    }
}
