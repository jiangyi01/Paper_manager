import Foundation

/// URL builders and pure response parsers for the four key-less metadata APIs
/// (docs/RESEARCH.md "pdf-storage-notify-dnd" §2). No I/O here: MetadataResolver
/// fetches through HostGate and hands the bytes to these functions.
///
/// Parsers return nil for a well-formed "nothing found" answer (arXiv with zero
/// entries, bioRxiv "no posts found", an empty Crossref list) and throw
/// `ParseError.malformed` for bytes that are not the expected format, so the
/// resolver can negative-cache the former and never cache the latter.
package enum MetadataClients {
    package static let userAgentProduct = "PaperDeck/0.1"

    package enum ParseError: Error, Equatable {
        case malformed(String)
    }

    package enum PreprintServer: String, Sendable, CaseIterable {
        case biorxiv, medrxiv
        package var displayName: String { self == .biorxiv ? "bioRxiv" : "medRxiv" }
    }

    // MARK: - Request identity

    /// "PaperDeck/0.1 (macOS)" or "PaperDeck/0.1 (macOS; mailto:x@y)". The address is a user
    /// setting (default none) that opts into Crossref's polite pool; it is never hardcoded.
    package static func userAgent(mailto: String?) -> String {
        if let m = sanitizedMailto(mailto) { return "\(userAgentProduct) (macOS; mailto:\(m))" }
        return "\(userAgentProduct) (macOS)"
    }

    /// Trimmed address if it looks like one plain email, else nil (it ends up in a header and URLs).
    package static func sanitizedMailto(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= 254 else { return nil }
        let pattern = #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$"#
        return s.range(of: pattern, options: .regularExpression) != nil ? s : nil
    }

    package static func requestHeaders(for url: URL, mailto: String?) -> [String: String] {
        let accept = url.host?.lowercased() == "export.arxiv.org" ? "application/atom+xml" : "application/json"
        return ["User-Agent": userAgent(mailto: mailto), "Accept": accept]
    }

    // MARK: - URL builders

    /// `id` is a base arXiv id; a version suffix is dropped so the latest metadata is returned.
    /// Old-style ids lose their subject class ("math.GT/0309136" → "math/0309136"), which the API expects.
    package static func arxivURL(id: String) -> URL? {
        var base = id.trimmingCharacters(in: .whitespaces)
        if base.lowercased().hasPrefix("arxiv:") { base = String(base.dropFirst(6)) }
        if let r = base.range(of: #"v\d+$"#, options: .regularExpression) { base.removeSubrange(r) }
        if let m = base.firstMatch(of: /^([A-Za-z\-]+)\.[A-Za-z]{2}\/(\d{7})$/) { base = "\(m.1)/\(m.2)" }
        guard base.range(of: #"^(\d{4}\.\d{4,5}|[A-Za-z\-]+/\d{7})$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://export.arxiv.org/api/query?id_list=\(base)")
    }

    package static func biorxivURL(doi: String, server: PreprintServer) -> URL? {
        guard let d = normalizeDOI(doi) else { return nil }
        return URL(string: "https://api.biorxiv.org/details/\(server.rawValue)/\(encodePath(d))")
    }

    package static func crossrefWorkURL(doi: String, mailto: String?) -> URL? {
        guard let d = normalizeDOI(doi) else { return nil }
        return URL(string: "https://api.crossref.org/works/\(encodePath(d))" + query([], mailto: mailto))
    }

    /// Elsevier PIIs are registered as Crossref `alternative-id`s.
    package static func crossrefPIIURL(pii: String, mailto: String?) -> URL? {
        let p = pii.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p.count <= 40 else { return nil }
        return URL(string: "https://api.crossref.org/works"
                   + query([("filter", "alternative-id:" + encodeQuery(p)), ("rows", "1")], mailto: mailto))
    }

    /// Bibliographic search for papers without identifiers; hits still need TitleSimilarity.
    package static func crossrefSearchURL(title: String, author: String?, mailto: String?) -> URL? {
        let t = collapseWhitespace(title)
        guard !t.isEmpty else { return nil }
        var items = [("query.bibliographic", encodeQuery(String(t.prefix(300))))]
        if let a = author.map(collapseWhitespace), !a.isEmpty { items.append(("query.author", encodeQuery(String(a.prefix(80))))) }
        items.append(("rows", "3"))
        return URL(string: "https://api.crossref.org/works" + query(items, mailto: mailto))
    }

    /// `select` trims the ~90 KB work object to the fields the parser reads.
    package static func openAlexWorkURL(doi: String, mailto: String?) -> URL? {
        guard let d = normalizeDOI(doi) else { return nil }
        let fields = "id,doi,title,display_name,publication_year,type,authorships,primary_location,abstract_inverted_index"
        return URL(string: "https://api.openalex.org/works/doi:\(encodePath(d))" + query([("select", fields)], mailto: mailto))
    }

    // MARK: - DOI helpers

    /// Lowercased bare DOI from "https://doi.org/10…", "doi:10…" or "10…"; nil if it is not a DOI.
    package static func normalizeDOI(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"]
        where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        s = s.lowercased()
        guard s.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil, s.count <= 300 else { return nil }
        return s
    }

    /// The preprint DOI without a trailing version ("…673319v2" → "…673319") when it is a
    /// bioRxiv/medRxiv id: 10.64898/* (bioRxiv since late 2025), or 10.1101/ followed by a
    /// date-stamped or legacy numeric id. Cold Spring Harbor journals share 10.1101 but use
    /// lettered suffixes ("gr.", "gad.") and go straight to Crossref.
    package static func biorxivDOI(_ doi: String) -> String? {
        guard var d = normalizeDOI(doi) else { return nil }
        if d.hasPrefix("10.64898/") { return d }
        guard d.hasPrefix("10.1101/") else { return nil }
        if let r = d.range(of: #"(?<=\d)v\d+$"#, options: .regularExpression) { d.removeSubrange(r) }
        let suffix = d.dropFirst("10.1101/".count)
        guard suffix.range(of: #"^(\d{4}\.\d{2}\.\d{2}\.\d{6}|\d{5,7})$"#, options: .regularExpression) != nil else { return nil }
        return d
    }

    package static func isBiorxivFamily(doi: String) -> Bool { biorxivDOI(doi) != nil }

    /// The same date-stamped bioRxiv id under the other prefix. File names only carry the suffix,
    /// so a "10.1101/…" guess for a 2026 preprint is really "10.64898/…" (and vice versa).
    package static func alternateBiorxivDOI(_ doi: String) -> String? {
        guard let d = biorxivDOI(doi), let slash = d.firstIndex(of: "/") else { return nil }
        let suffix = String(d[d.index(after: slash)...])
        guard suffix.range(of: #"^\d{4}\.\d{2}\.\d{2}\.\d{6}$"#, options: .regularExpression) != nil else { return nil }
        if d.hasPrefix("10.1101/") { return "10.64898/" + suffix }
        if d.hasPrefix("10.64898/") { return "10.1101/" + suffix }
        return nil
    }

    /// arXiv's DataCite DOI ("10.48550/arXiv.2606.24530") → "2606.24530".
    package static func arxivID(fromDOI doi: String) -> String? {
        guard let d = normalizeDOI(doi), d.hasPrefix("10.48550/arxiv.") else { return nil }
        let id = String(d.dropFirst("10.48550/arxiv.".count))
        return arxivURL(id: id) != nil ? id : nil
    }

    // MARK: - arXiv (Atom)

    /// Everything useful in one arXiv Atom entry; `parseArxiv` maps it to BiblioMetadata.
    package struct ArxivEntry: Sendable, Equatable {
        package var id: String                 // base id without version
        package var version: Int?
        package var title: String
        package var authors: [String]
        package var summary: String?
        package var published: String?         // ISO-8601 timestamp of v1
        package var updated: String?
        package var doi: String?               // journal DOI (arxiv:doi)
        package var journalRef: String?
        package var primaryCategory: String?
    }

    package static func parseArxivEntry(_ data: Data) throws -> ArxivEntry? {
        let collector = AtomCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse(), collector.sawFeed else {
            throw ParseError.malformed("arXiv Atom: \(parser.parserError?.localizedDescription ?? "no <feed>")")
        }
        guard let raw = collector.entries.first else { return nil }
        let idText = collapseWhitespace(raw["id"] ?? "")
        // The legacy API reports errors as an entry whose id points at /api/errors.
        guard !idText.contains("/api/errors"), let title = raw["title"].map(collapseWhitespace), !title.isEmpty,
              title.lowercased() != "error" else { return nil }
        var base = idText
        if let r = base.range(of: "/abs/") { base = String(base[r.upperBound...]) }
        var version: Int?
        if let m = base.firstMatch(of: /^(.+?)v(\d+)$/) {
            version = Int(m.2)
            base = String(m.1)
        }
        let doi = raw["doi"].flatMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        return ArxivEntry(
            id: base, version: version, title: title,
            authors: collector.authors.first.map { $0.map(collapseWhitespace).filter { !$0.isEmpty } } ?? [],
            summary: raw["summary"].map(collapseWhitespace).flatMap(nonEmpty),
            published: raw["published"].map(collapseWhitespace).flatMap(nonEmpty),
            updated: raw["updated"].map(collapseWhitespace).flatMap(nonEmpty),
            doi: normalizeDOI(doi),
            journalRef: raw["journal_ref"].map(collapseWhitespace).flatMap(nonEmpty),
            primaryCategory: raw["primary_category"].flatMap(nonEmpty))
    }

    package static func parseArxiv(_ data: Data) throws -> BiblioMetadata? {
        guard let e = try parseArxivEntry(data) else { return nil }
        return BiblioMetadata(
            title: e.title, authors: e.authors, year: e.published.flatMap(yearPrefix), venue: "arXiv",
            abstract: e.summary,
            ids: PaperIDs(arxivID: e.id.isEmpty ? nil : e.id, arxivVersion: e.version, publishedDOI: e.doi),
            source: .arxiv)
    }

    // MARK: - bioRxiv / medRxiv (details JSON)

    /// Title, authors and abstract come from the latest version; the year is the first posting's
    /// (matching Crossref's `issued` for the same DOI, so file names don't flip between sources).
    package static func parseBiorxiv(_ data: Data) throws -> BiblioMetadata? {
        let root = try decodeJSON(data, what: "bioRxiv")
        guard let collection = root["collection"]?.arrayValue else {
            throw ParseError.malformed("bioRxiv: no collection")
        }
        let versions = collection.filter { $0.objectValue != nil }
            .sorted { version(of: $0) < version(of: $1) }
        guard let latest = versions.last else { return nil }
        let title = latest["title"]?.stringValue.map(stripMarkup).flatMap(nonEmpty)
        let authors = (latest["authors"]?.stringValue ?? "")
            .split(separator: ";")
            .map { biorxivAuthor(String($0)) }
            .filter { !$0.isEmpty }
        guard title != nil || !authors.isEmpty else { return nil }
        let year = versions.compactMap { $0["date"]?.stringValue.flatMap(yearPrefix) }.min()
        let published = versions.reversed().lazy
            .compactMap { $0["published"]?.stringValue }
            .compactMap { normalizeDOI($0) }
            .first
        let server = latest["server"]?.stringValue?.lowercased()
        let venue = server == "medrxiv" ? "medRxiv" : "bioRxiv"
        return BiblioMetadata(
            title: title, authors: authors, year: year, venue: venue,
            abstract: latest["abstract"]?.stringValue.map(jatsToPlainText).flatMap(nonEmpty),
            ids: PaperIDs(doi: normalizeDOI(latest["doi"]?.stringValue), publishedDOI: published),
            source: .biorxiv)
    }

    // MARK: - Crossref (works JSON)

    /// One Crossref work plus the fields the resolver ranks search hits by.
    package struct CrossrefWork: Sendable, Equatable {
        package var meta: BiblioMetadata
        package var type: String?              // "journal-article", "posted-content", …
        package var score: Double?             // relevance, only on search results
        package var isPreprint: Bool { type == "posted-content" }
    }

    /// `/works/<doi>` → the single work.
    package static func parseCrossrefWork(_ data: Data) throws -> CrossrefWork? {
        let root = try decodeJSON(data, what: "Crossref")
        guard let message = root["message"], message.objectValue != nil else {
            throw ParseError.malformed("Crossref: no message")
        }
        if let items = message["items"]?.arrayValue { return items.lazy.compactMap(crossrefWork).first }
        return crossrefWork(message)
    }

    /// `/works?filter=…` or `?query.bibliographic=…` → works in Crossref's order.
    package static func parseCrossrefList(_ data: Data) throws -> [CrossrefWork] {
        let root = try decodeJSON(data, what: "Crossref")
        guard let message = root["message"], message.objectValue != nil else {
            throw ParseError.malformed("Crossref: no message")
        }
        guard let items = message["items"]?.arrayValue else {
            return crossrefWork(message).map { [$0] } ?? []
        }
        return items.compactMap(crossrefWork)
    }

    private static func crossrefWork(_ m: JSONValue) -> CrossrefWork? {
        guard m.objectValue != nil else { return nil }
        let doi = normalizeDOI(m["DOI"]?.stringValue)
        var title = firstString(m["title"]).map(stripMarkup).flatMap(nonEmpty)
        if let t = title, let sub = firstString(m["subtitle"]).map(stripMarkup).flatMap(nonEmpty),
           !TitleSimilarity.normalize(t).contains(TitleSimilarity.normalize(sub)) {
            title = "\(t): \(sub)"
        }
        let authors: [String] = (m["author"]?.arrayValue ?? []).compactMap { a in
            let given = a["given"]?.stringValue.map(stripMarkup).flatMap(nonEmpty)
            let family = a["family"]?.stringValue.map(stripMarkup).flatMap(nonEmpty)
            if let family { return given.map { "\($0) \(family)" } ?? family }
            return a["name"]?.stringValue.map(stripMarkup).flatMap(nonEmpty) ?? given
        }
        guard title != nil || !authors.isEmpty else { return nil }
        let year = ["issued", "published", "published-print", "published-online", "posted", "created"].lazy
            .compactMap { m[$0]?["date-parts"]?.arrayValue?.first?.arrayValue?.first?.intValue }
            .first { (1000...9999).contains($0) }
        let venue = firstString(m["container-title"]).map(stripMarkup).flatMap(nonEmpty)
            ?? firstString(m["short-container-title"]).map(stripMarkup).flatMap(nonEmpty)
            ?? m["institution"]?.arrayValue?.first?["name"]?.stringValue.map(stripMarkup).flatMap(nonEmpty)
            ?? doi.flatMap(venueForPrefix)
        let publishedDOI = (m["relation"]?["is-preprint-of"]?.arrayValue ?? [])
            .first { $0["id-type"]?.stringValue?.lowercased() == "doi" }
            .flatMap { normalizeDOI($0["id"]?.stringValue) }
        let pii = (m["alternative-id"]?.arrayValue ?? []).compactMap(\.stringValue)
            .first { $0.range(of: #"^S\d{15,16}[\dX]$"#, options: .regularExpression) != nil }
        let type = m["type"]?.stringValue
        let workType = [type, m["subtype"]?.stringValue].compactMap { $0.flatMap(nonEmpty) }.joined(separator: "/")
        return CrossrefWork(
            meta: BiblioMetadata(
                title: title, authors: authors, year: year, venue: venue,
                abstract: m["abstract"]?.stringValue.map(jatsToPlainText).flatMap(nonEmpty),
                ids: PaperIDs(doi: doi, pii: pii, publishedDOI: publishedDOI), source: .crossref,
                relations: crossrefRelations(m, own: doi), workType: workType.isEmpty ? nil : workType),
            type: type, score: m["score"]?.doubleValue)
    }

    /// Crossref names relations on either record (`asserted-by: object` means the other side
    /// deposited it), so a journal article often carries `has-preprint` → its preprint's DOI.
    /// Crossmark `update-to` makes this record a notice of the DOI it names. DOIs only, at most 32;
    /// a link to the record's own DOI is dropped.
    static func crossrefRelations(_ m: JSONValue, own: String?) -> [WorkRelation] {
        let names: [(String, WorkRelation.Kind)] = [
            ("has-preprint", .hasPreprint), ("is-preprint-of", .isPreprintOf), ("has-version", .hasVersion),
            ("is-version-of", .isVersionOf), ("is-identical-to", .isIdenticalTo), ("is-same-as", .isSameAs),
            ("replaces", .replaces), ("is-replaced-by", .isReplacedBy), ("is-comment-on", .isCommentOn),
            ("is-reply-to", .isReplyTo), ("is-supplement-to", .isSupplementTo),
        ]
        var out: [WorkRelation] = []
        func add(_ kind: WorkRelation.Kind, _ raw: String?) {
            guard out.count < 32, let d = normalizeDOI(raw), d != own else { return }
            let r = WorkRelation(kind: kind, doi: d)
            if !out.contains(r) { out.append(r) }
        }
        for (name, kind) in names {
            for r in m["relation"]?[name]?.arrayValue ?? [] where r["id-type"]?.stringValue?.lowercased() == "doi" {
                add(kind, r["id"]?.stringValue)
            }
        }
        for u in m["update-to"]?.arrayValue ?? [] { add(.correctionOf, u["DOI"]?.stringValue) }
        return out
    }

    /// Venue for posted content that has no container-title.
    private static func venueForPrefix(_ doi: String) -> String? {
        let table: [(String, String)] = [
            ("10.1101/", "bioRxiv"), ("10.64898/", "bioRxiv"), ("10.20944/", "Preprints.org"),
            ("10.21203/", "Research Square"), ("10.2139/", "SSRN"), ("10.48550/", "arXiv"),
            ("10.26434/", "ChemRxiv"), ("10.31219/", "OSF Preprints"), ("10.22541/", "Authorea"),
        ]
        return table.first { doi.hasPrefix($0.0) }?.1
    }

    // MARK: - OpenAlex (work JSON)

    package static func parseOpenAlexWork(_ data: Data) throws -> BiblioMetadata? {
        let root = try decodeJSON(data, what: "OpenAlex")
        guard root.objectValue != nil else { throw ParseError.malformed("OpenAlex: not an object") }
        let title = (root["title"]?.stringValue ?? root["display_name"]?.stringValue).map(stripMarkup).flatMap(nonEmpty)
        let authors: [String] = (root["authorships"]?.arrayValue ?? []).compactMap { a in
            (a["author"]?["display_name"]?.stringValue ?? a["raw_author_name"]?.stringValue)
                .map(stripMarkup).flatMap(nonEmpty)
        }
        guard title != nil || !authors.isEmpty else { return nil }
        let venue = root["primary_location"]?["source"]?["display_name"]?.stringValue.map(stripMarkup).flatMap(nonEmpty)
        let year = root["publication_year"]?.intValue.flatMap { (1000...9999).contains($0) ? $0 : nil }
        return BiblioMetadata(
            title: title, authors: authors, year: year, venue: venue,
            abstract: root["abstract_inverted_index"].flatMap(invertedIndexToText),
            ids: PaperIDs(doi: normalizeDOI(root["doi"]?.stringValue)), source: .openalex,
            openAlexID: openAlexWorkID(root["id"]?.stringValue))
    }

    /// "https://openalex.org/W4406155815" (or a bare "W…") → "W4406155815"; nil for anything else.
    package static func openAlexWorkID(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        for prefix in ["https://openalex.org/", "http://openalex.org/"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        guard s.range(of: #"^[Ww]\d{4,12}$"#, options: .regularExpression) != nil else { return nil }
        return "W" + s.dropFirst()
    }

    /// Rebuilds OpenAlex's `{word: [positions]}` abstract. Bounded because the input is untrusted.
    package static func invertedIndexToText(_ index: JSONValue) -> String? {
        guard let object = index.objectValue else { return nil }
        var placed: [(Int, String)] = []
        for (word, positions) in object {
            for p in positions.arrayValue ?? [] {
                guard let i = p.intValue, (0...200_000).contains(i) else { continue }
                placed.append((i, word))
                if placed.count > 50_000 { break }
            }
        }
        placed.sort { $0.0 < $1.0 }
        var words = placed.map(\.1)
        // OpenAlex sometimes keeps a stray leading "." or the heading "Abstract".
        while let first = words.first,
              first.rangeOfCharacter(from: .alphanumerics) == nil || first.lowercased() == "abstract" {
            words.removeFirst()
        }
        return nonEmpty(collapseWhitespace(words.joined(separator: " ")))
    }

    // MARK: - Text cleanup

    /// Inline markup removal for titles, names and venues: tags dropped, entities decoded, whitespace collapsed.
    package static func stripMarkup(_ s: String) -> String {
        collapseWhitespace(decodeEntities(removeTags(s) { name, _ in blockTags.contains(name) ? " " : "" }))
    }

    /// JATS (or light HTML) abstract → plain paragraphs separated by blank lines.
    /// A leading "Abstract"/"Summary" heading is dropped; other section titles become their own line.
    package static func jatsToPlainText(_ s: String) -> String {
        var paragraphs: [String] = []
        var current = ""
        func flush() {
            let text = collapseWhitespace(decodeEntities(current))
            current = ""
            guard !text.isEmpty else { return }
            let heading = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".: "))
            if paragraphs.isEmpty, ["abstract", "summary", "graphical abstract"].contains(heading) { return }
            paragraphs.append(text)
        }
        let body = removeTags(s) { name, _ in blockTags.contains(name) ? "\u{1}" : "" }
        for ch in body {
            if ch == "\u{1}" { flush() } else { current.append(ch) }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    private static let blockTags: Set<String> = ["p", "sec", "title", "list-item", "abstract", "br", "div", "li"]

    /// Replaces things that look like tags (`<` + optional `/` + letter … `>`) with whatever
    /// `replacement` returns for the tag's local name (namespace prefix removed, lowercased)
    /// and closing flag. A lone `<` as in "p < 0.05" is kept.
    private static func removeTags(_ s: String, replacement: (String, Bool) -> String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "<", let end = tagEnd(in: s, from: i) {
                var inner = s[s.index(after: i)..<end]
                let closing = inner.first == "/"
                if closing { inner = inner.dropFirst() }
                let rawName = inner.prefix { !$0.isWhitespace && $0 != "/" }
                let local = rawName.split(separator: ":").last.map { $0.lowercased() } ?? ""
                out += replacement(local, closing)
                i = s.index(after: end)
            } else {
                out.append(ch)
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func tagEnd(in s: String, from start: String.Index) -> String.Index? {
        var i = s.index(after: start)
        guard i < s.endIndex else { return nil }
        if s[i] == "/" { i = s.index(after: i) }
        guard i < s.endIndex, s[i].isASCII, s[i].isLetter else { return nil }
        var steps = 0
        while i < s.endIndex, steps < 512 {
            if s[i] == ">" { return i }
            if s[i] == "<" { return nil }
            i = s.index(after: i)
            steps += 1
        }
        return nil
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                       "ndash": "–", "mdash": "—", "hellip": "…", "thinsp": " ", "ensp": " ",
                                       "emsp": " ", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            guard ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") else {
                out.append(ch)
                i = s.index(after: i)
                continue
            }
            let name = s[s.index(after: i)..<semi]
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                replacement = named[String(name)]
            }
            if let replacement {
                out += replacement
                i = s.index(after: semi)
            } else {
                out.append(ch)
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "\u{1}" }).joined(separator: " ")
    }

    // MARK: - Small helpers

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private static func yearPrefix(_ s: String) -> Int? {
        guard s.count >= 4, let y = Int(s.prefix(4)), (1000...9999).contains(y) else { return nil }
        return y
    }

    private static func firstString(_ v: JSONValue?) -> String? {
        if let s = v?.stringValue { return s }
        return v?.arrayValue?.lazy.compactMap(\.stringValue).first
    }

    private static func version(of v: JSONValue) -> Int {
        v["version"]?.intValue ?? v["version"]?.stringValue.flatMap { Int($0) } ?? 0
    }

    /// "Miller, H. E." → "H. E. Miller"; names without a comma (consortia) are kept as-is.
    private static func biorxivAuthor(_ raw: String) -> String {
        let s = stripMarkup(raw)
        guard let comma = s.firstIndex(of: ",") else { return s }
        let family = s[..<comma].trimmingCharacters(in: .whitespaces)
        let given = s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        if family.isEmpty { return given }
        return given.isEmpty ? family : "\(given) \(family)"
    }

    private static func decodeJSON(_ data: Data, what: String) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw ParseError.malformed("\(what): invalid JSON") }
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encodeQuery(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// DOI in a path: keep `/` (and `:()` that Crossref accepts verbatim), encode everything else.
    private static func encodePath(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "/:()"))) ?? ""
    }

    /// Values in `items` must already be encoded; mailto is appended last and dropped from cache keys.
    private static func query(_ items: [(String, String)], mailto: String?) -> String {
        var all = items
        if let m = sanitizedMailto(mailto) { all.append(("mailto", encodeQuery(m))) }
        guard !all.isEmpty else { return "" }
        return "?" + all.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }
}

extension MetadataClients {
    /// Collects `<entry>` children of an Atom feed. Used synchronously inside one parse call.
    fileprivate final class AtomCollector: NSObject, XMLParserDelegate {
        private static let atom = "http://www.w3.org/2005/Atom"
        private static let arxiv = "http://arxiv.org/schemas/atom"

        var sawFeed = false
        var entries: [[String: String]] = []
        var authors: [[String]] = []

        private var inEntry = false
        private var inAuthor = false
        private var capture: String?
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let ns = namespaceURI ?? ""
            if elementName == "feed" && (ns == Self.atom || ns.isEmpty) { sawFeed = true; return }
            if elementName == "entry" && (ns == Self.atom || ns.isEmpty) {
                inEntry = true
                entries.append([:])
                authors.append([])
                return
            }
            guard inEntry, let last = entries.indices.last else { return }
            switch (ns, elementName) {
            case (Self.atom, "author"), ("", "author"):
                inAuthor = true
            case (Self.atom, "name"), ("", "name"):
                if inAuthor { capture = "author.name"; buffer = "" }
            case (Self.atom, "id"), (Self.atom, "title"), (Self.atom, "summary"),
                 (Self.atom, "published"), (Self.atom, "updated"):
                if !inAuthor { capture = elementName; buffer = "" }
            case (Self.arxiv, "doi"), (Self.arxiv, "journal_ref"):
                capture = elementName; buffer = ""
            case (Self.arxiv, "primary_category"):
                if let term = attributeDict["term"] { entries[last]["primary_category"] = term }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capture != nil { buffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if elementName == "entry" { inEntry = false; inAuthor = false; capture = nil; return }
            if elementName == "author" { inAuthor = false }
            guard let key = capture, let last = entries.indices.last else { return }
            let finished = key == "author.name" ? elementName == "name" : elementName == key
            guard finished else { return }
            if key == "author.name" {
                authors[last].append(buffer)
            } else if entries[last][key] == nil {
                entries[last][key] = buffer
            }
            capture = nil
            buffer = ""
        }
    }
}
