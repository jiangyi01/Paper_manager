import Foundation

/// Pure text helpers of the duplicate check (dive-dedupe §3): kinds and vetoes from titles and
/// file names, the parts of a title that name one member of a family (BRCA1 vs BRCA2, Part I
/// vs II), author surnames, and the tokens of the FTS candidate query.
package enum DedupeText {
    /// TitleSimilarity's normal form ("β-Catenin in vivo" → "beta catenin in vivo").
    package static func titleNorm(_ title: String) -> String { TitleSimilarity.normalize(title) }

    // MARK: Kinds

    /// What the title, the file name, the page count and a Crossref record say the document is.
    package static func kind(title: String, fileName: String? = nil, workType: String? = nil,
                             relations: [WorkRelation] = []) -> DupKind {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = workType?.lowercased() ?? ""
        if type.hasPrefix("component") || relations.contains(where: { $0.kind == .isSupplementTo })
            || matches(t, supplementTitle) || fileName.map(isSupplementFileName) == true {
            return .supplement
        }
        if matches(t, noticeTitle) || matches(t, noticeTrailer) || relations.contains(where: { $0.kind == .correctionOf }) {
            return .notice
        }
        if matches(t, commentTitle) || relations.contains(where: { $0.kind == .isCommentOn || $0.kind == .isReplyTo }) {
            return .comment
        }
        if type.hasPrefix("peer-review") || matches(t, reviewTitle) { return .review }
        if isGeneric(titleNorm(title)) { return .generic }
        return .article
    }

    /// The original title a notice or comment names ("Author Correction: X" → "X"); nil when
    /// the title has no such prefix.
    package static func noticeTarget(_ title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [noticeTitle, commentTitle] {
            if let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let rest = t[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :–—-\"“”'"))
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }

    /// File names publishers give supplements: Cell `mmc1.pdf`, Springer `…_MOESM1_ESM.pdf`,
    /// bioRxiv `media-1.pdf`, PLOS `….s001.pdf`, PNAS `….sapp.pdf`, and the import's own
    /// supplement words (`supp`, `SI`, `extended data`).
    package static func isSupplementFileName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.range(of: #"^mmc\d+\.pdf$|_moesm\d+_esm\.pdf$|^media-\d+\.pdf$|\.s\d{3}\.pdf$|\.sapp\.pdf$"#,
                   options: .regularExpression) != nil { return true }
        return IntakeActor.isSupplementName(name)
    }

    // The notice / comment / review / supplement words count only when the title is just that
    // word, or a separator follows it (a colon, a quote, a dash, a bracket: "Author Correction: X",
    // "Corrigendum to “X”", "Reply to: X") — never when an ordinary word does: "Correction of
    // sickle cell disease by base editing", "Response to immune checkpoint blockade", "Review of
    // single-cell methods" and "Supporting information networks in hospital teams" are articles.
    // Crossref's relations (`update-to`, `is-comment-on`, `component`) count on their own.

    /// What may follow the kind's words: the end, or a separator.
    private static let separator = #"\s*(?:$|[:："“”'‘’«\[(—–]|-\s)"#
    // "Online …" counts only as a bare section title ("Online Methods", "Online data: …"), never
    // with a following preposition: "Online methods for …" / "Online data from …" are articles.
    static let supplementTitle = #"^(?:(?:(?:supplementary|supplemental|supporting)\s+(?:information|materials?|data|text|appendix|appendices|methods|figures?|tables?|notes?|files?|videos?|movies?|discussion)(?:\s+(?:and|&)\s+(?:information|materials?|data|text|methods|figures?|tables?|notes?|discussion))*|extended data(?:\s+(?:figures?|tables?))?|si appendix|appendix|appendices|electronic supplementary material)(?:\s*$|\s*[:：.,;"“'‘\[(—–]|-\s|\s+(?:for|to|of|on|from|in)\b|\s+s?\d+\b|\s+[a-z]\b|\s+[ivx]+\b)|online\s+(?:methods|data|information|appendix|supplementary\s+(?:information|materials?))(?:\s*$|\s*[:：.,;"“'‘\[(—–]|-\s|\s+s?\d+\b))"#
    static let noticeTitle = #"^(?:author |publisher |editorial |editor'?s'? )?(?:correction|corrections|erratum|errata|corrigendum|corrigenda|addendum|retraction(?: note| notice)?|retracted(?: article| paper)?|withdrawn|withdrawal(?: note| notice)?|expression of concern|notice of (?:retraction|correction|concern))(?:\s+(?:to|for|of|on)(?:\s+the)?(?:\s+(?:research\s+|original\s+)?(?:article|report|letter|paper|review|perspective|communication|brief communication|editorial|study|comment)s?)?)?"# + separator
    static let noticeTrailer = #"\(vol\.? \d+, pg?\.? ?\d+, \d{4}\)\s*$"#
    static let commentTitle = #"^(?:matters arising\b|re:\s|authors?'?\s+reply\b|(?:reply|replies|response|responses|comment|comments|commentary|rebuttal)\s+(?:to|on)\b.{0,80}\bet\s+al\b|(?:(?:reply|replies|response|responses|comment|comments|commentary|rebuttal)\s+(?:to|on)|re-?analysis\s+of)(?:\s+(?:the|a|an))?(?:\s+(?:comment|reply|response|commentary|letter|article|paper|correspondence|analysis)s?)?(?:\s+(?:by|from|on|of))?"# + separator + ")"
    static let reviewTitle = #"^(?:decision letter\b|peer review (?:file|history|report)s?\b|transparent peer review\b|reviewer(?:s'?)? reports?\b|referee reports?\b|reviewer\s*#?\s*\d|elife assessment\b|(?:author response|review of|response to (?:the )?(?:reviewers?|referees?)|reviewers?'? comments?)(?:\s+(?:for|to|on)\b|"# + separator + "))"

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Titles too short or too general to compare (title rules are skipped; only ids and text count).
    package static func isGeneric(_ norm: String) -> Bool {
        // CJK titles are one "word" to the normalizer: count characters instead.
        if isCJK(norm) { return norm.filter { !$0.isWhitespace }.count < 6 }
        let words = norm.split(separator: " ")
        if norm.count < 12 || words.count < 3 { return true }
        return genericTitles.contains(norm)
    }

    /// The two normalized titles have at least one word (≥ 3 letters, or with a digit) in common.
    package static func shareAWord(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if isCJK(a) || isCJK(b) { return true }          // one "word" per CJK run: let the score decide
        let wb = Set(b.split(separator: " ").filter { $0.count >= 3 || $0.contains(where: \.isNumber) })
        return a.split(separator: " ").contains { ($0.count >= 3 || $0.contains(where: \.isNumber)) && wb.contains($0) }
    }

    /// The words of a normalized title, as `TitleSimilarity` compares them (a set).
    package static func titleWords(_ norm: String) -> Set<String> {
        Set(norm.split(separator: " ").map(String.init))
    }

    /// Whether `TitleSimilarity.score` of a title with words `a` and the normalized title `b` could
    /// reach `threshold` — a cheap upper bound (no edit distances) that lets the tombstone scan skip
    /// most rows: the score is half word overlap, half edit similarity, so it stays below
    /// ½·overlap + ½. The overlap counts the shared words plus every possible near match between
    /// the long words left over, with slack for split or glued words. CJK titles (one "word" per
    /// run) always may.
    package static func mayReachTitleScore(_ a: Set<String>, _ b: String, _ threshold: Double) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if isCJK(b) || a.contains(where: isCJK) { return true }
        let wb = titleWords(b)
        let exact = a.intersection(wb).count
        let near = min(a.subtracting(wb).count(where: { $0.count >= 5 }), wb.subtracting(a).count(where: { $0.count >= 5 }))
        let m = Double(exact + near)
        let overlap = m / (Double(a.count + wb.count) - m)
        return 0.5 * min(1, overlap + 0.15) + 0.5 >= threshold
    }

    /// The shorter title (≥ 4 words, not generic) is the start of the longer one — a subtitle
    /// added or dropped on publication ("X" vs "X: insights into Y").
    package static func prefixContained(_ a: String, _ b: String) -> Bool {
        let wa = a.split(separator: " "), wb = b.split(separator: " ")
        let (short, long) = wa.count <= wb.count ? (wa, wb) : (wb, wa)
        guard short.count >= 4, long.count > short.count, !isGeneric(short.joined(separator: " ")) else { return false }
        return Array(long.prefix(short.count)) == short
    }

    static let genericTitles: Set<String> = [
        "introduction", "editorial", "preface", "foreword", "highlights", "in this issue", "abstracts",
        "supplementary information", "supplementary material", "table of contents", "contents", "front matter",
        "back matter", "index", "letter to the editor", "book review", "editors note", "research highlights",
        "news and views", "meeting abstracts", "conference abstracts", "program and abstracts",
    ]

    // MARK: Vetoes

    /// What names one member of a family of titles: the digits (also inside words: "brca1"),
    /// series numerals, Greek letters, species and in vivo / in vitro (dive-dedupe §3.3).
    package static func discriminators(_ norm: String) -> (digits: String, marks: Set<String>) {
        let w = norm.split(separator: " ").map(String.init)
        var marks = Set<String>()
        for (i, t) in w.enumerated() {
            if romans.contains(t), i > 0, seriesWords.contains(w[i - 1]) || (i == w.count - 1 && t != "i" && t != "v") {
                marks.insert("r:" + t)
            } else if greekNames.contains(t) || species.contains(t) || ["vivo", "vitro", "silico", "situ"].contains(t) {
                marks.insert(t)
            }
        }
        return (norm.filter(\.isNumber), marks)
    }

    static let romans: Set<String> = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
    static let seriesWords: Set<String> = ["part", "paper", "phase", "series", "chapter", "volume", "study", "section"]
    static let species: Set<String> = ["human", "mouse", "murine", "rat", "zebrafish", "drosophila", "yeast",
                                       "arabidopsis", "macaque", "primate", "chicken", "xenopus", "worm", "elegans"]
    static let greekNames: Set<String> = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
                                          "kappa", "lambda", "sigma", "omega"]

    /// Both titles name the same member of a family (no veto).
    package static func sameDiscriminators(_ a: String, _ b: String) -> Bool {
        let x = discriminators(a), y = discriminators(b)
        return x.digits == y.digits && x.marks == y.marks
    }

    /// Han, kana or hangul in the title (unicode61 can't segment it; the title threshold is stricter).
    package static func isCJK(_ s: String) -> Bool { FTSQuery.containsCJK(s) }

    // MARK: Authors

    /// Normalized surnames of the first `limit` authors; consortia and groups are dropped.
    package static func surnames(_ authors: [String], limit: Int = 8) -> [String] {
        var out: [String] = []
        for a in authors.prefix(limit + 4) where out.count < limit {
            let lower = a.lowercased()
            if groupWords.contains(where: { lower.contains($0) }) { continue }
            guard let s = MailMatcher.surname(a) else { continue }
            let n = TitleSimilarity.normalize(s).replacingOccurrences(of: " ", with: "")
            if n.count >= 2, !out.contains(n) { out.append(n) }
        }
        return out
    }

    static let groupWords = ["consortium", "collaboration", "group", "network", "initiative", "project", "team",
                             "investigators", "committee", "society", "atlas program"]

    /// A surname from a PDF's Author attribute ("Li Wang, Ada Lovelace" / "Wang L; Smith J").
    package static func attributeSurnames(_ raw: String?) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let parts = raw.split(whereSeparator: { ";\n".contains($0) }).flatMap { part -> [Substring] in
            // "A, B and C" lists vs "Wang, Li" (one name): split on commas only when there are several words each side.
            let pieces = part.split(separator: ",")
            if pieces.count > 1, pieces.allSatisfy({ $0.split(separator: " ").count >= 2 }) { return pieces }
            return [part]
        }
        var names: [String] = []
        for part in parts { names += String(part).components(separatedBy: " and ") }
        return surnames(names)
    }

    // MARK: FTS candidates

    /// Raw-title words for the bm25 candidate query (dive-dedupe §4.1): the index holds "β", not
    /// "beta", so normalized words would miss. Stopwords and short words out, at most `limit`.
    package static func queryTokens(_ title: String, limit: Int = 12) -> [String] {
        var out: [String] = []
        var word = String.UnicodeScalarView()
        func flush() {
            let w = String(word).lowercased()
            word = String.UnicodeScalarView()
            guard w.count >= 3 || w.contains(where: \.isNumber), !stopwords.contains(w), !out.contains(w) else { return }
            out.append(w)
        }
        for u in title.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) { word.append(u) } else { flush() }
        }
        flush()
        // Longer words are rarer: keep those when the title is long.
        if out.count > limit { out = Array(out.sorted { $0.count > $1.count }.prefix(limit)) }
        return out
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "that", "this", "these", "those", "via", "using", "use",
        "are", "was", "were", "has", "have", "its", "their", "our", "new", "not", "but", "can", "all", "how", "what",
        "why", "when", "who", "between", "within", "across", "through", "during", "after", "before", "under",
        "over", "toward", "towards", "based", "study", "analysis", "approach", "method", "methods",
    ]
}
