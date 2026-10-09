import Foundation

/// Finds DOI / arXiv / Elsevier PII identifiers for a dropped PDF (§6.1).
///
/// Sources are ranked by how reliably they describe *this* file: publisher XMP and the PDF
/// Title attribute, then publisher file-name patterns, then the first pages' text. Page 1–2
/// can cite other works, so text DOIs are ignored once a confident arXiv id exists, and a bare
/// "arXiv:" mention only counts when no DOI was found. Bare `\d{4}\.\d{5}` is never matched.
package enum Identifiers {

    package static func detect(fileName: String, firstPagesText: String, attributeTitle: String?, xmpHead: Data?) -> PaperIDs {
        let name = (fileName as NSString).lastPathComponent
        let xmp = xmpHead.flatMap { String(data: $0, encoding: .isoLatin1) } ?? ""
        let textDOIs = doiCandidates(in: firstPagesText)

        // arXiv from confident sources: file name, XMP dc:identifier or the Info /DOI key, and the
        // arXiv watermark with its "[category]". Raw bytes also hold link annotations to cited
        // preprints, so only those two metadata keys are read from them.
        var arxiv = arxivFromFileName(name)
            ?? firstArxiv(xmpArxivRegex, in: xmp)
            ?? firstArxiv(infoArxivDOIRegex, in: xmp)
            ?? firstArxiv(arxivStampRegex, in: firstPagesText)
            ?? firstArxiv(arxivOldStampRegex, in: firstPagesText)

        // DOI from confident sources.
        let xmpDOI = firstXMPDOI(in: xmp)
        let titleDOI = attributeTitle.flatMap(doiFromTitleAttribute)
        let fileDOI = doiFromFileName(name, reconcilingWith: [xmpDOI].compactMap { $0 } + textDOIs.map(\.doi))
        var doi = xmpDOI ?? titleDOI ?? fileDOI
        if doi == nil, arxiv == nil {
            let usable = textDOIs.filter { !isDataRepositoryDOI($0.doi) }
            doi = usable.first(where: \.labeled)?.doi ?? usable.first?.doi
        }
        if doi == nil, arxiv == nil {
            arxiv = firstArxiv(arxivPlainRegex, in: firstPagesText)
                ?? firstArxiv(arxivOldPlainRegex, in: firstPagesText)
                ?? firstArxiv(arxivDOIRegex, in: firstPagesText)
                ?? firstArxiv(arxivURLRegex, in: firstPagesText)
        }

        return PaperIDs(doi: doi, arxivID: arxiv?.id, arxivVersion: arxiv?.version, pii: piiFromFileName(name))
    }

    // MARK: File names

    /// "2606.24530v2.pdf" → ("2606.24530", 2); validated against arXiv's YYMM rules.
    static func arxivFromFileName(_ name: String) -> (id: String, version: Int?)? {
        guard let g = groups(arxivFileRegex, in: name), let id = g[1], isValidArxivID(id) else { return nil }
        return (id, g[2].flatMap { Int($0) })
    }

    /// Publisher file names that encode the DOI. bioRxiv's prefix changed from 10.1101 to
    /// 10.64898 in 2025, so a text/XMP DOI ending in the same date-id wins over the guess.
    static func doiFromFileName(_ name: String, reconcilingWith known: [String]) -> String? {
        if let g = groups(biorxivFileRegex, in: name), let id = g[1], isPlausibleBiorxivDate(id) {
            let suffix = "/" + id.lowercased()
            return known.first(where: { $0.hasSuffix(suffix) }) ?? "10.1101/" + id
        }
        if let g = groups(springerFileRegex, in: name), let code = g[1], let journal = g[2] {
            // s41…–s44… are Nature Portfolio (10.1038); s12…, s13…, s40… are BMC/SpringerOpen (10.1186).
            // Other Springer codes map to several prefixes, so they are left to XMP / text.
            let prefix: String
            switch journal.prefix(2) {
            case "41", "42", "43", "44": prefix = "10.1038"
            case "12", "13", "40": prefix = "10.1186"
            default: return nil
            }
            return prefix + "/" + code.lowercased()
        }
        if let g = groups(preprintsFileRegex, in: name), let id = g[1], let v = g[2] {
            return "10.20944/preprints\(id).v\(v)"
        }
        return nil
    }

    /// Elsevier "1-s2.0-S0092867424013321-main.pdf" → "S0092867424013321".
    static func piiFromFileName(_ name: String) -> String? {
        groups(piiFileRegex, in: name)?[1].map { $0.uppercased() }
    }

    // MARK: DOIs

    /// Crossref's pattern, then trailing `.,;:` and unbalanced `)` stripped, lower-cased.
    static func cleanDOI(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last {
            if ".,;:".contains(last) { s.removeLast(); continue }
            if last == ")", s.filter({ $0 == "(" }).count < s.filter({ $0 == ")" }).count { s.removeLast(); continue }
            break
        }
        guard doiShapeRegex.firstMatch(in: s, range: fullRange(s)) != nil else { return nil }
        return s.lowercased()
    }

    /// DOIs in text order; `labeled` when preceded by "doi:", "DOI " or "doi.org/".
    /// A DOI broken at a line end after "-", "." or "/" is re-joined with the next line.
    static func doiCandidates(in text: String) -> [(doi: String, labeled: Bool)] {
        let ns = text as NSString
        var out: [(String, Bool)] = []
        var seen = Set<String>()
        for m in doiRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var raw = ns.substring(with: m.range)
            let end = NSMaxRange(m.range)
            if let last = raw.last, "-./".contains(last), end < ns.length, ns.character(at: end) == 0x0A,
               let cont = doiContinuationRegex.firstMatch(in: text, options: [.anchored],
                                                          range: NSRange(location: end + 1, length: ns.length - end - 1)) {
                raw += ns.substring(with: cont.range)
            }
            guard let doi = cleanDOI(raw), !doi.hasPrefix("10.48550/"), seen.insert(doi).inserted else { continue }
            let lookback = max(0, m.range.location - 20)
            let before = ns.substring(with: NSRange(location: lookback, length: m.range.location - lookback))
                .lowercased().trimmingCharacters(in: .whitespaces)
            let labeled = before.hasSuffix("doi.org/") || before.hasSuffix("doi:") || before.hasSuffix("doi")
            out.append((doi, labeled))
        }
        return out
    }

    /// Dataset / protocol registries cited on page 1–2 are never the paper's own DOI.
    static func isDataRepositoryDOI(_ doi: String) -> Bool {
        let prefixes = ["10.5281/", "10.6084/", "10.5061/", "10.17632/", "10.24433/", "10.17504/", "10.35077/", "10.7910/"]
        return prefixes.contains { doi.hasPrefix($0) }
    }

    /// Elsevier sometimes stores "doi:10.1016/…" as the Title attribute.
    static func doiFromTitleAttribute(_ title: String) -> String? {
        groups(titleDOIRegex, in: title)?[1].flatMap(cleanDOI)
    }

    static func firstXMPDOI(in xmp: String) -> String? {
        guard !xmp.isEmpty else { return nil }
        for re in xmpDOIRegexes {
            if let raw = groups(re, in: xmp)?[1], let doi = cleanDOI(raw), !doi.hasPrefix("10.48550/") { return doi }
        }
        return nil
    }

    // MARK: arXiv

    /// New-style ids: 4-digit sequence only for 0704–1412, 5-digit from 1501. Old-style
    /// "archive/YYMMNNN" ids run from 9108 to 0703.
    static func isValidArxivID(_ id: String) -> Bool {
        if let slash = id.lastIndex(of: "/") {
            let num = id[id.index(after: slash)...]
            guard num.count == 7, let yy = Int(num.prefix(2)), let mm = Int(num.dropFirst(2).prefix(2)),
                  (1...12).contains(mm) else { return false }
            if yy >= 91 { return true }
            return yy < 7 || (yy == 7 && mm <= 3)
        }
        let parts = id.split(separator: ".")
        guard parts.count == 2, parts[0].count == 4, let yymm = Int(parts[0]),
              (1...12).contains(yymm % 100), parts[1].allSatisfy(\.isNumber) else { return false }
        switch parts[1].count {
        case 4: return (704...1412).contains(yymm)
        case 5: return yymm >= 1501
        default: return false
        }
    }

    private static func firstArxiv(_ re: NSRegularExpression, in text: String) -> (id: String, version: Int?)? {
        guard !text.isEmpty else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            guard isValidArxivID(id) else { continue }
            let vr = m.range(at: 2)
            return (id, vr.location == NSNotFound ? nil : Int(ns.substring(with: vr)))
        }
        return nil
    }

    // MARK: Helpers

    private static func groups(_ re: NSRegularExpression, in s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    private static func fullRange(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    private static func isPlausibleBiorxivDate(_ id: String) -> Bool {
        let p = id.split(separator: ".")
        guard p.count == 4, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return false }
        return (2013...2099).contains(y) && (1...12).contains(m) && (1...31).contains(d)
    }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: options) }
        catch { preconditionFailure("Identifiers: bad pattern \(pattern): \(error)") }
    }

    private static let newID = #"\d{4}\.\d{4,5}"#
    private static let oldID = #"[a-z][a-z\-]+(?:\.[a-z]{2})?/\d{7}"#

    private static let arxivFileRegex = rx(#"^("# + newID + #")(?:v(\d+))?(?:\.pdf)?$"#)
    private static let biorxivFileRegex = rx(#"(?<![\d.])(\d{4}\.\d{2}\.\d{2}\.\d{6})(?:v\d+)?(?:\.full)?\.pdf$"#)
    private static let springerFileRegex = rx(#"^(s(\d{5})-\d{3}-\d{5}-\w)\.pdf$"#)
    private static let preprintsFileRegex = rx(#"preprints(\d{6}\.\d{4})\.v(\d+)"#)
    private static let piiFileRegex = rx(#"1-s2\.0-(S\d{15,16}[\dX])-main\.pdf"#)

    private static let arxivStampRegex = rx(#"\barXiv:\s*("# + newID + #")(?:v(\d+))?\s*\[[a-z\-]+(?:\.[a-z\-]+)?\]"#)
    private static let arxivOldStampRegex = rx(#"\barXiv:\s*("# + oldID + #")(?:v(\d+))?\s*\[[a-z\-]+(?:\.[a-z\-]+)?\]"#)
    private static let arxivOldPlainRegex = rx(#"\barXiv:\s*("# + oldID + #")(?:v(\d+))?\b"#)
    private static let arxivPlainRegex = rx(#"\barXiv:\s*(\d{2}(?:0[1-9]|1[0-2])\.\d{4,5})(?:v(\d+))?\b"#)
    private static let arxivURLRegex = rx(#"arxiv\.org/(?:abs|pdf|html)/("# + newID + "|" + oldID + #")(?:v(\d+))?"#)
    private static let arxivDOIRegex = rx(#"\b10\.48550/arxiv\.("# + newID + #")(?:v(\d+))?"#)
    private static let infoArxivDOIRegex = rx(#"/DOI\s*\(\s*(?:doi:|https?://(?:dx\.)?doi\.org/)?10\.48550/arxiv\.("# + newID + #")(?:v(\d+))?"#)
    private static let xmpArxivRegex = rx(#"dc:identifier(?:\s*=\s*"|>)\s*(?:https?://)?arxiv\.org/abs/("# + newID + "|" + oldID + #")(?:v(\d+))?"#)

    private static let doiRegex = rx(#"\b10\.\d{4,9}/[-._;()/:A-Z0-9]+"#)
    private static let doiContinuationRegex = rx(#"[-._;()/:A-Z0-9]+"#)
    private static let doiShapeRegex = rx(#"^10\.\d{4,9}/\S+$"#)
    private static let titleDOIRegex = rx(#"^\s*(?:doi:\s*|https?://(?:dx\.)?doi\.org/)?(10\.\d{4,9}/\S+)\s*$"#)
    private static let xmpDOIRegexes: [NSRegularExpression] = [
        rx(#"<prism:doi>\s*(?:doi:|https?://(?:dx\.)?doi\.org/)?(10\.\d{4,9}/[^<\s]+)\s*<"#),
        rx(#"prism:doi\s*=\s*"(?:doi:|https?://(?:dx\.)?doi\.org/)?(10\.\d{4,9}/[^"\s]+)""#),
        rx(#"<(?:pdfx:doi|crossmark:DOI)>\s*(?:doi:|https?://(?:dx\.)?doi\.org/)?(10\.\d{4,9}/[^<\s]+)\s*<"#),
        rx(#"<dc:identifier>\s*(?:doi:|https?://(?:dx\.)?doi\.org/)(10\.\d{4,9}/[^<\s]+)\s*<"#),
        rx(#"/DOI\s*\(\s*(?:doi:|https?://(?:dx\.)?doi\.org/)?(10\.\d{4,9}/[^)\s]+)\s*\)"#),
    ]
}
