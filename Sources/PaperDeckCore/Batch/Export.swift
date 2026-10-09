import Foundation

/// Export ▸ BibTeX / RIS / CSV / Markdown for a multi-selection (DQ §5.4; READING_ASSIST_PLAN §6.4
/// C1): metadata only — never a PDF, the notes, the AI card or the checklist. Pure; the App copies
/// the text to the clipboard or writes it through a save panel. Owned by Slice C.
package enum BatchExport {
    package enum Format: String, Sendable, CaseIterable {
        case bibtex, ris, csv, markdown

        package var fileExtension: String {
            switch self {
            case .bibtex: return "bib"
            case .ris: return "ris"
            case .csv: return "csv"
            case .markdown: return "md"
            }
        }
    }

    /// One paper as exported.
    package struct Entry: Sendable, Equatable {
        package var title: String
        package var authors: [String]
        package var year: Int?
        package var venue: String?
        package var doi: String?
        package var arxivID: String?
        package var abstract: String?
        package var status: PaperStatus
        package var priority: Priority
        package var deadline: LocalDate?
        package var category: String?
        package var tags: [String]
        package var addedAt: Date

        package init(title: String, authors: [String] = [], year: Int? = nil, venue: String? = nil, doi: String? = nil,
                     arxivID: String? = nil, abstract: String? = nil, status: PaperStatus = .toRead,
                     priority: Priority = .normal, deadline: LocalDate? = nil, category: String? = nil,
                     tags: [String] = [], addedAt: Date = Date(timeIntervalSince1970: 0)) {
            self.title = title; self.authors = authors; self.year = year; self.venue = venue; self.doi = doi
            self.arxivID = arxivID; self.abstract = abstract; self.status = status; self.priority = priority
            self.deadline = deadline; self.category = category; self.tags = tags; self.addedAt = addedAt
        }

        /// A library row: the visible (non-suppressed) tags, the category's name.
        package init(_ row: PaperRow) {
            let p = row.paper
            self.init(title: p.title, authors: p.authors, year: p.year, venue: p.venue, doi: p.ids.doi,
                      arxivID: p.ids.arxivID, abstract: p.abstract, status: p.status, priority: p.priority,
                      deadline: p.scheduleMode == .none ? nil : p.deadline, category: row.category?.name,
                      tags: row.tags.filter { $0.origin != .suppressed }.map(\.name), addedAt: p.addedAt)
        }
    }

    package static func text(_ entries: [Entry], format: Format) -> String {
        switch format {
        case .bibtex: return bibtex(entries)
        case .ris: return ris(entries)
        case .csv: return csv(entries)
        case .markdown: return markdown(entries)
        }
    }

    // MARK: BibTeX

    /// `@article` (a venue) or `@misc`; UTF-8 text with the LaTeX specials escaped; keys like
    /// `Wang2024Molecular`, made unique with a / b / c… — against every key already written, so a
    /// suffixed key never equals a later entry's own key ("Data" + a = "Dataa").
    package static func bibtex(_ entries: [Entry]) -> String {
        var next: [String: Int] = [:]                  // base key → the next suffix to try
        var emitted: Set<String> = []
        var out: [String] = []
        for e in entries {
            let base = citeKey(e)
            var n = next[base, default: 0]
            var key = n == 0 ? base : base + suffix(n)
            while emitted.contains(key) {
                n += 1
                key = base + suffix(n)
            }
            next[base] = n + 1
            emitted.insert(key)
            var fields: [(String, String)] = [("title", latex(oneLine(e.title)))]
            if !e.authors.isEmpty { fields.append(("author", e.authors.map { latex(oneLine($0)) }.joined(separator: " and "))) }
            if let y = e.year { fields.append(("year", String(y))) }
            let isArticle = e.venue.map { !oneLine($0).isEmpty } ?? false
            if let v = e.venue, isArticle { fields.append(("journal", latex(oneLine(v)))) }
            if let doi = e.doi { fields.append(("doi", latex(oneLine(doi)))) }
            if let arxiv = e.arxivID {
                fields.append(("eprint", latex(oneLine(arxiv))))
                fields.append(("archiveprefix", "arXiv"))
            }
            if let url = url(e) { fields.append(("url", latexURL(url))) }
            let body = fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
            out.append("@\(isArticle ? "article" : "misc"){\(key),\n\(body)\n}")
        }
        return out.isEmpty ? "" : out.joined(separator: "\n\n") + "\n"
    }

    /// First author's surname + year + first significant title word, ASCII letters and digits only.
    package static func citeKey(_ e: Entry) -> String {
        let surname = e.authors.first.map(surnameOf).map(asciiWord) ?? ""
        let stop: Set<String> = ["a", "an", "the", "on", "of", "in", "for", "and", "to", "with", "from", "by", "at"]
        let word = oneLine(e.title).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { asciiWord(String($0)) }
            .first { !$0.isEmpty && !stop.contains($0.lowercased()) } ?? ""
        let key = capitalized(surname) + (e.year.map(String.init) ?? "") + capitalized(word)
        return key.isEmpty ? "paper" : key
    }

    /// "Wang, Li" → Wang; "Li Wang" → Wang; "王力" → 王力.
    static func surnameOf(_ author: String) -> String {
        let a = oneLine(author)
        if let comma = a.firstIndex(of: ",") { return String(a[..<comma]).trimmingCharacters(in: .whitespaces) }
        return a.split(separator: " ").last.map(String.init) ?? a
    }

    /// Latin transliteration, diacritics stripped, ASCII letters and digits only ("Müller" → Muller,
    /// "王" → wang).
    static func asciiWord(_ s: String) -> String {
        let latin = s.applyingTransform(.toLatin, reverse: false) ?? s
        let folded = latin.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0)) }.map(Character.init))
    }

    private static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return "" }
        return f.uppercased() + s.dropFirst()
    }

    private static func suffix(_ n: Int) -> String {
        // 1 → a, 2 → b, … 26 → z, 27 → aa
        var n = n, out = ""
        repeat {
            n -= 1
            out = String(UnicodeScalar(UInt8(97 + n % 26))) + out
            n /= 26
        } while n > 0
        return out
    }

    /// Escapes the LaTeX specials so a title like "C++ & R: 100% {new}" survives BibTeX.
    package static func latex(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "&": out += "\\&"
            case "%": out += "\\%"
            case "$": out += "\\$"
            case "#": out += "\\#"
            case "_": out += "\\_"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            default: out.append(ch)
            }
        }
        return out
    }

    /// URLs keep their characters (biblatex reads `url` verbatim); only braces are unsafe there.
    private static func latexURL(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "%7B").replacingOccurrences(of: "}", with: "%7D")
    }

    // MARK: RIS

    /// RIS (CRLF lines, `TY` … `ER`): JOUR when a venue is known, else GEN.
    package static func ris(_ entries: [Entry]) -> String {
        var lines: [String] = []
        func add(_ tag: String, _ value: String?) {
            guard let v = value.map(oneLine), !v.isEmpty else { return }
            lines.append("\(tag)  - \(v)")
        }
        for e in entries {
            let isArticle = e.venue.map { !oneLine($0).isEmpty } ?? false
            lines.append("TY  - \(isArticle ? "JOUR" : "GEN")")
            add("TI", e.title)
            for a in e.authors { add("AU", a) }
            add("PY", e.year.map(String.init))
            if isArticle { add("JO", e.venue) }
            add("DO", e.doi)
            add("UR", url(e))
            add("AB", e.abstract)
            for t in e.tags { add("KW", t) }
            lines.append("ER  - ")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Parses `ris(_:)` output back (tests: the round trip).
    package static func parseRIS(_ text: String) -> [[String: [String]]] {
        var out: [[String: [String]]] = []
        var current: [String: [String]] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard line.count >= 6, line.dropFirst(2).hasPrefix("  - ") || line.dropFirst(2).hasPrefix("  -") else { continue }
            let tag = String(line.prefix(2))
            let value = String(line.dropFirst(6))
            if tag == "ER" { out.append(current); current = [:]; continue }
            current[tag, default: []].append(value)
        }
        return out
    }

    // MARK: CSV

    package static let csvHeader = ["title", "authors", "year", "venue", "doi", "arxiv", "status", "priority",
                                    "deadline", "category", "tags", "added"]

    /// RFC 4180 (CRLF, quotes doubled). A cell that a spreadsheet would run as a formula (`=` `+` `-`
    /// `@` first) gets a leading apostrophe.
    package static func csv(_ entries: [Entry]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        var rows = [csvHeader]
        for e in entries {
            rows.append([
                oneLine(e.title), e.authors.map(oneLine).joined(separator: "; "), e.year.map(String.init) ?? "",
                e.venue.map(oneLine) ?? "", e.doi ?? "", e.arxivID ?? "", e.status.rawValue, priorityName(e.priority),
                e.deadline?.iso ?? "", e.category.map(oneLine) ?? "", e.tags.joined(separator: "; "),
                iso.string(from: e.addedAt),
            ])
        }
        return rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func csvCell(_ raw: String) -> String {
        var s = raw
        if let f = s.first, "=+-@\t\r".contains(f) { s = "'" + s }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Parses RFC 4180 text (tests: the round trip).
    package static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = ""
        var quoted = false
        var chars = Array(text)
        var i = 0
        if chars.last?.isNewline != true { chars.append("\n") }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { quoted = false }
                } else { cell.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(cell); cell = ""
            } else if c == "\r\n" || c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(cell); rows.append(row); row = []; cell = ""
            } else {
                cell.append(c)
            }
            i += 1
        }
        return rows
    }

    // MARK: Markdown

    /// A list: `- **Title** — Authors (Year). *Venue*. [doi:…](https://doi.org/…)`.
    package static func markdown(_ entries: [Entry]) -> String {
        var lines: [String] = []
        for e in entries {
            var line = "- **\(md(oneLine(e.title)))**"
            if !e.authors.isEmpty {
                let names = e.authors.count > 3 ? e.authors.prefix(3).map(oneLine) + ["et al."] : e.authors.map(oneLine)
                line += " — " + md(names.joined(separator: ", "))
            }
            if let y = e.year { line += " (\(y))" }
            line += "."
            if let v = e.venue.map(oneLine), !v.isEmpty { line += " *\(md(v))*." }
            if let doi = e.doi, let link = url(e) { line += " [doi:\(md(doi))](\(link))" }
            else if let arxiv = e.arxivID, let link = url(e) { line += " [arXiv:\(md(arxiv))](\(link))" }
            lines.append(line)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Backslash-escapes Markdown's inline specials.
    static func md(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]<>#|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: Shared

    /// doi.org for a DOI, else arxiv.org/abs for an arXiv id (percent-encoded path).
    static func url(_ e: Entry) -> String? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#[]@!$&'()*+,;="))
        if let doi = e.doi.map(oneLine), !doi.isEmpty {
            return "https://doi.org/" + (doi.addingPercentEncoding(withAllowedCharacters: allowed) ?? doi)
        }
        if let arxiv = e.arxivID.map(oneLine), !arxiv.isEmpty {
            return "https://arxiv.org/abs/" + (arxiv.addingPercentEncoding(withAllowedCharacters: allowed) ?? arxiv)
        }
        return nil
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func priorityName(_ p: Priority) -> String {
        switch p {
        case .high: return "high"
        case .normal: return "normal"
        case .low: return "low"
        }
    }
}
