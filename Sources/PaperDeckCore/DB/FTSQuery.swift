import Foundation

/// How a search-box string is executed (§5). FTS5 is the default; unicode61
/// cannot segment CJK and prefix indexes start at 2 characters, so CJK and very
/// short input fall back to LIKE; DOI/arXiv-shaped input is an exact id lookup.
package enum FTSQuery: Sendable, Equatable {
    case empty
    case match(String)      // safe FTS5 MATCH expression (every token quoted)
    case like(String)       // raw trimmed needle; build the pattern with `likePattern`
    case doi(String)        // lowercased DOI
    case arxiv(String)      // base arXiv id, version stripped

    private static let maxTokens = 16
    private static let keywords: Set<String> = ["AND", "OR", "NOT", "NEAR"]

    package init(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { self = .empty; return }
        if let doi = FTSQuery.parseDOI(trimmed) { self = .doi(doi); return }
        if let arxiv = FTSQuery.parseArxivID(trimmed) { self = .arxiv(arxiv); return }
        if FTSQuery.containsCJK(trimmed) || trimmed.count < 3 { self = .like(trimmed); return }
        if let expr = FTSQuery.matchExpression(trimmed) { self = .match(expr) } else { self = .empty }
    }

    /// Quotes every whitespace-separated word (so FTS5 syntax — quotes, `*`, `^`,
    /// `:`, parentheses, bare AND/OR/NOT/NEAR — is inert) and prefix-matches the last.
    /// Inside quotes FTS5 re-tokenizes, so `single-cell` becomes the phrase "single cell".
    /// nil when nothing searchable remains.
    package static func matchExpression(_ input: String) -> String? {
        var tokens: [String] = []
        for word in input.split(whereSeparator: { $0.isWhitespace }) {
            var scalars = String.UnicodeScalarView()
            for u in word.unicodeScalars { scalars.append(isTokenScalar(u) ? u : " ") }
            let cleaned = String(scalars).split(separator: " ").joined(separator: " ")
            guard !cleaned.isEmpty, !keywords.contains(cleaned) else { continue }
            tokens.append("\"\(cleaned)\"")
            if tokens.count == maxTokens { break }
        }
        guard !tokens.isEmpty else { return nil }
        tokens[tokens.count - 1] += "*"
        return tokens.joined(separator: " ")
    }

    /// Any one of `tokens` (Explain's paper locator: rare words of noisy OCR text; LN §5): each
    /// cleaned like `matchExpression` — non-token characters become spaces and the word is quoted, so
    /// FTS5 syntax (quotes, `*`, `^`, `:`, parentheses, column filters, bare AND/OR/NOT/NEAR) is inert —
    /// then joined with OR. Duplicates (case-insensitive) and keywords are dropped; at most `limit`
    /// words. No prefix match. nil when nothing searchable remains. `matchExpression` is an AND, too
    /// strict for OCR; bm25 still ranks the papers holding more of the words first.
    package static func anyOf(_ tokens: [String], limit: Int = 10) -> String? {
        var seen = Set<String>()
        var out: [String] = []
        for token in tokens {
            guard out.count < max(limit, 0) else { break }
            var scalars = String.UnicodeScalarView()
            for u in token.unicodeScalars { scalars.append(isTokenScalar(u) ? u : " ") }
            let cleaned = String(scalars).split(separator: " ").joined(separator: " ")
            guard !cleaned.isEmpty, !keywords.contains(cleaned.uppercased()), seen.insert(cleaned.lowercased()).inserted
            else { continue }
            out.append("\"\(cleaned)\"")
        }
        return out.isEmpty ? nil : out.joined(separator: " OR ")
    }

    /// `%needle%` with LIKE wildcards escaped; use with `ESCAPE '\'`.
    package static func likePattern(_ needle: String) -> String {
        var out = "%"
        for ch in needle {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out + "%"
    }

    /// A bare DOI, `doi:` form or doi.org URL → lowercased DOI.
    package static func parseDOI(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/",
                       "doi.org/", "doi:"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard s.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil else { return nil }
        while let last = s.last, ".,;:".contains(last) { s.removeLast() }
        if s.hasSuffix(")"), s.filter({ $0 == "(" }).count < s.filter({ $0 == ")" }).count { s.removeLast() }
        return s.lowercased()
    }

    /// `2606.24530v2`, `arXiv:2606.24530`, arxiv.org abs/pdf/html URLs, or an
    /// old-style id like `math.GT/0309136` → base id without version.
    package static func parseArxivID(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^(https?://)?(www\.)?arxiv\.org/(abs|pdf|html)/"#,
                           options: [.regularExpression, .caseInsensitive]) {
            s = String(s[r.upperBound...])
        } else if s.lowercased().hasPrefix("arxiv:") {
            s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if s.lowercased().hasSuffix(".pdf") { s = String(s.dropLast(4)) }
        let modern = #"^(\d{4}\.\d{4,5})(v\d+)?$"#
        let legacy = #"^([a-zA-Z-]+(\.[A-Z]{2})?/\d{7})(v\d+)?$"#
        guard s.range(of: modern, options: .regularExpression) != nil
                || s.range(of: legacy, options: .regularExpression) != nil else { return nil }
        if let v = s.range(of: #"v\d+$"#, options: .regularExpression) { s.removeSubrange(v) }
        return s
    }

    /// True if any scalar is Han, kana, Hangul or CJK punctuation/full-width.
    package static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            switch u.value {
            case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x31FF,
                 0x3200...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF,
                 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
                return true
            default:
                return false
            }
        }
    }

    /// Letters, digits and combining marks — what unicode61 keeps inside a token.
    private static func isTokenScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber, .privateUse:
            return true
        default:
            return false
        }
    }
}
