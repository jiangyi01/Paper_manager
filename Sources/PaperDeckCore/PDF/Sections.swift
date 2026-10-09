import Foundation

/// Finds section headings, main-figure numbers and the extent of the main text in
/// PDF-extracted page text (§6.4). `TextPreparer` reuses the same line classifiers so
/// the checklist and the agent input agree on what counts as a heading.
package enum Sections {

    /// Builds the structure from per-page text. `outline` is the PDF's top-level outline as
    /// (label, 1-based page); it wins when ≥ 3 of its entries look like section headings,
    /// and text-detected kinds it lacks (Abstract, References, Data availability…) are merged in.
    package static func analyze(pageTexts: [String], outline: [(title: String, page: Int)]?) -> DocumentStructure {
        let lines = splitLines(pageTexts)
        let headings = classify(lines)
        let refLike = lines.map { isReferenceLike($0.text) }
        let refStart = lines.map { isReferenceStart($0.text) }
        let owner = owners(lines: lines, headings: headings, refLike: refLike)
        let unheaded = unheadedReferenceMask(refLike: refLike, refStart: refStart)

        // Text hits: first occurrence per kind, keyed by (page, line) for document order.
        var hits: [SectionKind: (page: Int, pos: Int, title: String)] = [:]
        for (i, h) in headings.enumerated() {
            guard let h, let kind = h.sectionKind, hits[kind] == nil else { continue }
            hits[kind] = (lines[i].page, i, lines[i].text.trimmingCharacters(in: .whitespaces))
        }

        var fromOutline = false
        var outlineBoundaryPages: [Int] = []
        if let outline {
            var mapped: [(kind: SectionKind, title: String, page: Int)] = []
            for entry in outline {
                guard entry.page >= 1, entry.page <= max(pageTexts.count, 1),
                      let kind = classifyTitle(entry.title, page: entry.page, requireCapital: false)?.sectionKind
                else { continue }
                mapped.append((kind, entry.title.trimmingCharacters(in: .whitespacesAndNewlines), entry.page))
            }
            if mapped.count >= 3 {
                fromOutline = true
                var outlineHits: [SectionKind: (page: Int, pos: Int, title: String)] = [:]
                for m in mapped where outlineHits[m.kind] == nil {
                    // Outline entries carry no line position: borrow the text heading's, else the
                    // first line on that page mentioning the label, else the page's first line.
                    let pos: Int
                    if let t = hits[m.kind], t.page == m.page { pos = t.pos }
                    else {
                        let needle = m.title.lowercased()
                        let onPage = lines.indices.filter { lines[$0].page == m.page }
                        pos = onPage.first { lines[$0].text.lowercased().contains(needle) } ?? onPage.first ?? lines.count
                    }
                    outlineHits[m.kind] = (m.page, pos, m.title)
                    if [.references, .supplementary, .extendedData].contains(m.kind) { outlineBoundaryPages.append(m.page) }
                }
                hits.merge(outlineHits) { _, outlineHit in outlineHit }
            }
        }

        let sections = hits
            .sorted { a, b in (a.value.page, a.value.pos) < (b.value.page, b.value.pos) }
            .map { SectionHit(kind: $0.key, title: $0.value.title, page: $0.value.page) }

        // Main text ends at References / Supplementary / Extended Data or an unheaded reference list.
        // Candidates in the first quarter of the document are ignored (tables of contents, cover pages).
        var candidates: [Int] = []
        for (i, h) in headings.enumerated() {
            guard let h else { continue }
            switch h {
            case .section(.references), .section(.supplementary), .section(.extendedData),
                 .extendedDataLegend, .supplementaryLegend:
                candidates.append(i)
            default: break
            }
        }
        if let firstUnheaded = unheaded.firstIndex(of: true) { candidates.append(firstUnheaded) }
        for page in outlineBoundaryPages {
            if let i = lines.firstIndex(where: { $0.page >= page }) { candidates.append(i) }
        }
        let minBoundary = lines.count / 4
        let boundary = candidates.filter { $0 >= minBoundary }.min() ?? lines.count

        var mainWords = 0
        var benchmarks = 0
        for line in lines[..<boundary] {
            mainWords += wordCount(line.text)
            benchmarks += benchmarkRegex.numberOfMatches(in: line.text, range: fullRange(line.text))
        }

        var figureSource: [String] = []
        for i in lines.indices where !unheaded[i] {
            switch owner[i] {
            case .section(.references)?, .section(.supplementary)?, .section(.extendedData)?,
                 .extendedDataLegend?, .supplementaryLegend?:
                continue
            default:
                figureSource.append(lines[i].text)
            }
        }
        let figures = mainFigureNumbers(in: figureSource.joined(separator: "\n"))

        let fullText = pageTexts.joined(separator: "\n")
        let hasED = hits[.extendedData] != nil
            || extendedDataMention.firstMatch(in: fullText, range: fullRange(fullText)) != nil
        let hasSupp = hits[.supplementary] != nil
            || supplementaryMention.firstMatch(in: fullText, range: fullRange(fullText)) != nil
            || supplementaryFigureS.firstMatch(in: fullText, range: fullRange(fullText)) != nil

        return DocumentStructure(sections: sections, sectionsFromOutline: fromOutline,
                                 mainFigureNumbers: figures, hasExtendedData: hasED,
                                 hasSupplementary: hasSupp, mainWordCount: mainWords,
                                 benchmarkMentions: benchmarks)
    }

    /// Distinct main-figure numbers from "Fig. 2", "Figure 3b", "Figs. 1–3", ignoring
    /// Extended Data / Supplementary / "SFig" references. Numbers that jump far past the
    /// previous one (a cited figure of another paper) end the run; at most 12 are kept.
    package static func mainFigureNumbers(in text: String) -> [Int] {
        let ns = text as NSString
        var found = Set<Int>()
        for m in figureRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = m.range.location
            let lookback = max(0, start - 24)
            let before = ns.substring(with: NSRange(location: lookback, length: start - lookback))
            if figurePrefixExclusion.firstMatch(in: before, range: fullRange(before)) != nil { continue }
            if before.hasSuffix("S") { continue }          // "SFig. 3", "SFigure 2"
            var match: NSTextCheckingResult? = m
            // "Figs 2 and 3", "Fig. 1b, 2c": follow the list after the first number.
            while let current = match {
                if let n = Int(ns.substring(with: current.range(at: 1))), n >= 1 {
                    found.insert(n)
                    if current.range(at: 2).location != NSNotFound, let hi = Int(ns.substring(with: current.range(at: 2))),
                       hi > n, hi - n <= 12 {
                        for k in (n + 1)...hi { found.insert(k) }
                    }
                }
                let next = NSMaxRange(current.range)
                match = figureListRegex.firstMatch(in: text, options: [.anchored],
                                                   range: NSRange(location: next, length: ns.length - next))
            }
        }
        var result: [Int] = []
        for n in found.sorted() {
            if let last = result.last { if n > last + 2 { break } } else if n > 3 { break }
            result.append(n)
            if result.count == 12 { break }
        }
        return result
    }
}

// MARK: - Line model and classifiers shared with TextPreparer

extension Sections {

    struct Line: Sendable, Equatable {
        var page: Int          // 1-based
        var text: String       // trimmed, never empty
    }

    /// Every heading either consumer cares about — a superset of `SectionKind`.
    enum Heading: Sendable, Equatable {
        case section(SectionKind)                 // §6.4 kinds plus references / acknowledgements
        case authorContributions, competingInterests, reportingSummary
        case funding, backMatter, appendix        // terminate a section, never dropped
        case extendedDataLegend, supplementaryLegend

        var sectionKind: SectionKind? {
            switch self {
            case .section(let k): return k
            case .extendedDataLegend: return .extendedData
            case .supplementaryLegend: return .supplementary
            default: return nil
            }
        }

        var isLegend: Bool { self == .extendedDataLegend || self == .supplementaryLegend }
    }

    static func splitLines(_ pageTexts: [String]) -> [Line] {
        var out: [Line] = []
        for (i, page) in pageTexts.enumerated() {
            for raw in page.split(whereSeparator: \.isNewline) {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(Line(page: i + 1, text: t)) }
            }
        }
        return out
    }

    static func classify(_ lines: [Line]) -> [Heading?] {
        var seenReferences = false
        return lines.map { line in
            if let h = classifyLine(line.text, page: line.page) {
                if h == .section(.references) { seenReferences = true }
                return h
            }
            if seenReferences, line.text.count <= 60, !line.text.contains(","),
               appendixLetterRegex.firstMatch(in: line.text, range: fullRange(line.text)) != nil {
                return .appendix
            }
            return nil
        }
    }

    /// Standalone short heading (≤ 60 chars), then run-in heading ("Acknowledgements We thank…"),
    /// then Extended Data / Supplementary legend start ("Extended Data Fig. 3 | …").
    static func classifyLine(_ text: String, page: Int) -> Heading? {
        guard let first = text.unicodeScalars.first else { return nil }
        if text.count <= 60, let h = classifyTitle(text, page: page, requireCapital: true) { return h }
        let c = Character(first)
        if "ACDFRSOPacdfrsop".contains(c), let h = runInHeading(text) { return h }
        if "EeSsFfTt".contains(c) {
            if edLegendRegex.firstMatch(in: text, range: fullRange(text)) != nil { return .extendedDataLegend }
            if suppLegendRegex.firstMatch(in: text, range: fullRange(text)) != nil { return .supplementaryLegend }
        }
        return nil
    }

    /// Classifies a whole line / outline label as a heading. Section numbers ("4.", "IV.") are
    /// stripped; sub-section numbers ("3.2") are rejected so sub-headings don't split sections.
    static func classifyTitle(_ raw: String, page: Int, requireCapital: Bool) -> Heading? {
        var core = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var numbered = false
        if let m = numberingRegex.firstMatch(in: core, range: fullRange(core)) {
            core = (core as NSString).substring(from: m.range.length)
            numbered = true
        }
        var colon = false
        while let last = core.last, last == ":" || last == "." { colon = colon || last == ":"; core.removeLast() }
        core = core.trimmingCharacters(in: .whitespaces)
        guard let first = core.unicodeScalars.first, first.properties.isAlphabetic || first == "★" else { return nil }
        if requireCapital, !(first.properties.isUppercase) { return nil }
        guard core.split(separator: " ").count <= 8,
              let m = standaloneRegex.firstMatch(in: core, range: fullRange(core)) else { return nil }
        func has(_ name: String) -> Bool { m.range(withName: name).location != NSNotFound }
        // "Conclusion:" alone on a line is usually a label inside a figure or transcript; only
        // abstract and back-matter headings are written with a colon (MDPI "Acknowledgments:").
        if colon, !["abstract", "data", "code", "references", "ack", "contrib", "competing", "funding"].contains(where: has) {
            return nil
        }

        if has("abstract") { return .section(.abstract) }
        if has("summary") { return page <= 2 ? .section(.abstract) : nil }
        if has("introduction") { return .section(.introduction) }
        if has("background") { return .section(.background) }
        if has("results") { return .section(.results) }
        if has("result") { return numbered ? .section(.results) : nil }
        if has("discussion") { return .section(.discussion) }
        if has("conclusion") { return .section(.conclusion) }
        if has("methods") { return .section(.methods) }
        // Singular "Method" / "Evaluation" are common table headers; trust them only when numbered.
        if has("method") { return numbered ? .section(.methods) : nil }
        if has("experiments") { return .section(.experiments) }
        if has("evaluation") { return numbered ? .section(.evaluation) : nil }
        if has("related") { return .section(.relatedWork) }
        if has("data") { return .section(.dataAvailability) }
        if has("code") { return .section(.codeAvailability) }
        if has("extended") { return .section(.extendedData) }
        if has("supplementary") { return .section(.supplementary) }
        if has("references") { return .section(.references) }
        if has("ack") { return .section(.acknowledgements) }
        if has("contrib") { return .authorContributions }
        if has("competing") { return .competingInterests }
        if has("reporting") { return .reportingSummary }
        if has("funding") { return .funding }
        if has("backmatter") { return .backMatter }
        if has("appendix") { return .appendix }
        return nil
    }

    static func runInHeading(_ text: String) -> Heading? {
        guard let m = runInRegex.firstMatch(in: text, range: fullRange(text)) else { return nil }
        func has(_ name: String) -> Bool { m.range(withName: name).location != NSNotFound }
        if has("abstract") { return .section(.abstract) }
        if has("ack") { return .section(.acknowledgements) }
        if has("contrib") { return .authorContributions }
        if has("competing") { return .competingInterests }
        if has("reporting") { return .reportingSummary }
        if has("data") { return .section(.dataAvailability) }
        if has("code") { return .section(.codeAvailability) }
        if has("funding") { return .funding }
        if has("backmatter") { return .backMatter }
        return nil
    }

    /// The heading governing each line (nil = front matter / unknown). Short back-matter
    /// sections (acknowledgements…) expire after 60 lines; a headed reference list ends early
    /// when 30 consecutive lines stop looking like references (an unrecognised appendix heading).
    /// Legends govern only until the next page.
    static func owners(lines: [Line], headings: [Heading?], refLike: [Bool]) -> [Heading?] {
        var owner = [Heading?](repeating: nil, count: lines.count)
        var section: Heading? = nil
        var sectionStart = 0
        var legend: Heading? = nil
        var legendPage = 0
        for i in lines.indices {
            if let h = headings[i] {
                if h.isLegend { legend = h; legendPage = lines[i].page }
                else { section = h; sectionStart = i; legend = nil }
            } else if legend != nil, lines[i].page != legendPage {
                legend = nil
            }
            if let s = section, s.expiresQuickly, i - sectionStart > 60 { section = nil }
            owner[i] = legend ?? section
        }
        // Soft end of headed reference lists.
        var i = 0
        while i < lines.count {
            guard owner[i] == .section(.references) else { i += 1; continue }
            var end = i
            while end < lines.count, owner[end] == .section(.references) { end += 1 }
            if end - i > 30 {
                var count = 0
                for k in (i + 1)..<(i + 31) where refLike[k] { count += 1 }
                var s = i + 1
                while s + 30 <= end {
                    if count < 6 {
                        for k in s..<end { owner[k] = nil }
                        break
                    }
                    if refLike[s] { count -= 1 }
                    if s + 30 < end, refLike[s + 30] { count += 1 }
                    s += 1
                }
            }
            i = end
        }
        return owner
    }

    /// Lines inside unheaded reference lists: any 30-line window where ≥ 60% of lines look like
    /// references marks the span from its first reference-start line to its last reference-like line.
    static func unheadedReferenceMask(refLike: [Bool], refStart: [Bool], window: Int = 30) -> [Bool] {
        let n = refLike.count
        var mask = [Bool](repeating: false, count: n)
        guard n >= 10 else { return mask }
        let w = min(window, n)
        let need = Int((Double(w) * 0.6).rounded(.up))
        var prefix = [Int](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + (refLike[k] ? 1 : 0) }
        var markedUpTo = -1
        for s in 0...(n - w) where prefix[s + w] - prefix[s] >= need {
            guard let a = (s..<(s + w)).first(where: { refStart[$0] }),
                  let b = (s..<(s + w)).last(where: { refLike[$0] }) else { continue }
            let from = max(a, markedUpTo + 1)
            guard from <= b else { continue }
            for k in from...b { mask[k] = true }
            markedUpTo = b
        }
        return mask
    }

    /// A line that starts a reference entry: "12. Smith", "[3]", "1. 2. 3. Molnár, Z.",
    /// "Long, H. K., Prescott…", "Samuel Alber, Bowen Chen, …".
    static func isReferenceStart(_ text: String) -> Bool {
        referenceStartRegex.firstMatch(in: text, range: fullRange(text)) != nil
    }

    /// A reference entry start or continuation: year in parentheses at the end, ", 2023.",
    /// volume/pages, DOI links, "arXiv preprint", "In Proceedings".
    static func isReferenceLike(_ text: String) -> Bool {
        isReferenceStart(text) || referenceCueRegex.firstMatch(in: text, range: fullRange(text)) != nil
    }

    static func wordCount(_ s: String) -> Int {
        var n = 0
        var inWord = false, hasLetter = false
        for u in s.unicodeScalars {
            if u.properties.isWhitespace {
                if inWord && hasLetter { n += 1 }
                inWord = false; hasLetter = false
            } else {
                inWord = true
                if u.properties.isAlphabetic { hasLetter = true }
            }
        }
        if inWord && hasLetter { n += 1 }
        return n
    }

    static func fullRange(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
}

private extension Sections.Heading {
    /// Back-matter blocks that are always short; a missed terminator must not swallow the paper.
    var expiresQuickly: Bool {
        switch self {
        case .section(.acknowledgements), .authorContributions, .competingInterests, .reportingSummary,
             .funding, .backMatter:
            return true
        default:
            return false
        }
    }
}

// MARK: - Patterns

extension Sections {
    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: options) }
        catch { preconditionFailure("Sections: bad pattern \(pattern): \(error)") }
    }

    private static let numberingRegex = rx(#"^(?:\d{1,2}\.?|[IVX]{1,5}\.)\s+"#)

    /// §6.4 heading list plus the back-matter kinds TextPreparer drops or stops at.
    private static let standaloneRegex = rx("^(?:" + [
        #"(?<abstract>abstract)"#, #"(?<summary>summary)"#, #"(?<introduction>introduction)"#,
        #"(?<background>background)"#, #"(?<results>results)"#, #"(?<result>result)"#,
        #"(?<discussion>discussions?|general\s+discussion)"#,
        #"(?<conclusion>conclusions?|concluding\s+remarks)"#,
        #"(?<methods>(?:online\s+|star\s*[★☆*+]?\s*)?methods|materials?\s+(?:and|&)\s+methods|experimental\s+procedures)"#,
        #"(?<method>method|methodology)"#, #"(?<experiments>experiments)"#, #"(?<evaluation>evaluation)"#,
        #"(?<related>related\s+works?)"#,
        #"(?<data>data\s+(?:(?:and|&)\s+(?:code|materials?|software)\s+)?availability(?:\s+statement)?|availability\s+of\s+data(?:\s+and\s+materials?)?)"#,
        #"(?<code>(?:code|software)\s+availability(?:\s+statement)?)"#,
        #"(?<extended>extended\s+data(?:\s+(?:figures?|tables?|items?))?)"#,
        #"(?<supplementary>supplement(?:ary|al)(?:\s+(?:information|materials?|data|figures?|tables?|notes?|methods|text|files?|results))?)"#,
        #"(?<references>references(?:\s+(?:and|&)\s+notes)?|bibliography|literature\s+cited|works\s+cited)"#,
        #"(?<ack>acknowledge?ments?)"#,
        #"(?<contrib>authors?[’']?\s*contributions?|contributions\s+of\s+authors|credit\s+authorship\s+contribution\s+statement)"#,
        #"(?<competing>competing\s+(?:financial\s+)?interests?|conflicts?\s+of\s+interests?(?:\s+statement)?|declarations?\s+of\s+(?:competing\s+)?interests?|disclosures?)"#,
        #"(?<reporting>reporting\s+summary)"#,
        #"(?<funding>funding(?:\s+(?:sources|information|statement))?|financial\s+support)"#,
        #"(?<backmatter>online\s+content|additional\s+information|peer\s+review\s+information|ethics\s+declarations|ethics\s+statement|author\s+information|abbreviations)"#,
        #"(?<appendix>appendix(?:\s+[a-z0-9]{1,3})?(?:\s*[.:]\s*.{0,50})?|appendices)"#,
    ].joined(separator: "|") + #")(?:\s+(?:and|&)\s+\p{L}[\p{L}\s\-]{0,40})?$"#)

    /// Lettered appendix headings ("A. Package and Environment Details", "B Case Studies");
    /// only trusted after the reference list, where they end it.
    private static let appendixLetterRegex = rx(#"^[A-H](?:\.\d{1,2})*\.?\s+\p{Lu}[\p{L}\-]*(?:\s+[\p{L}\d\-&]+){0,8}$"#, [])

    /// Run-in headings: the heading, then a separator or an upper-case word on the same line.
    private static let runInRegex = rx("^(?:" + [
        #"(?<abstract>abstract)"#, #"(?<ack>acknowledge?ments?)"#,
        #"(?<contrib>authors?[’']?\s*contributions?)"#,
        #"(?<competing>competing\s+(?:financial\s+)?interests?|conflicts?\s+of\s+interests?|declarations?\s+of\s+(?:competing\s+)?interests?)"#,
        #"(?<reporting>reporting\s+summary)"#,
        #"(?<data>data\s+(?:(?:and|&)\s+(?:code|materials?)\s+)?availability(?:\s+statement)?)"#,
        #"(?<code>code\s+availability)"#, #"(?<funding>funding)"#,
        #"(?<backmatter>additional\s+information|peer\s+review\s+information|supplementary\s+information|online\s+content)"#,
    ].joined(separator: "|") + #")(?:\s*[:|.—–]\s*\S|\s+(?-i:[\p{Lu}\d]))"#)

    private static let edLegendRegex = rx(#"^Extended\s+Data\s+(?:Fig(?:ure)?s?\.?|Table)\s*\d{1,2}\s*(?:[|:.]|\s[–—-]\s)"#)
    private static let suppLegendRegex = rx(#"^(?:Supplement(?:ary|al)\s+(?:Fig(?:ure)?s?\.?|Table)\s*S?\d{1,2}|(?-i:(?:Fig(?:ure)?\.?|Table)\s*S\d{1,2}))\s*(?:[|:.]|\s[–—-]\s)"#)

    private static let referenceStartRegex = rx([
        #"^\s*\[?\d{1,3}[\].]\s+\p{Lu}"#,                                  // §6.2: "12. Smith", "[12] Smith"
        #"^\s*\[\d{1,3}\]"#,
        #"^\s*(?:\d{1,3}\.\s+){2,}"#,                                      // PDFKit collapses Nature numbering: "1. 2. 3. Molnár"
        #"^\p{Lu}[\p{L}'’\-]+(?:\s(?:\p{Lu}[\p{L}'’\-]+|van|von|de|der|den|da|di|del|dos|du|la|le|el|al))*,\s(?:\p{Lu}\.\s?-?\s?){1,3}(?:,|&|and\b|et\sal|\(|\p{Lu}\p{Ll})"#,
        #"^(?:\p{Lu}[\p{L}'’\-.]*\s){1,3}\p{Lu}[\p{L}'’\-]+,\s(?:\p{Lu}[\p{L}'’\-.]*\s){1,3}\p{Lu}[\p{L}'’\-]+,"#,
    ].joined(separator: "|"), [])

    private static let referenceCueRegex = rx([
        #"\((?:19|20)\d{2}[a-z]?\)[.,;]?\s*$"#,
        #",\s(?:19|20)\d{2}[a-z]?\.\s*$"#,
        #"\b(?:19|20)\d{2}[a-z]?\.\s+(?:URL\b|doi:?|https?://)"#,
        #"(?i:arxiv\spreprint|preprint\sat\b|in\sproceedings|proceedings\sof\b|advances\sin\sneural)"#,
        #"\bdoi:\s*10\.|https?://doi\.org/10\.|\bURL\shttps?://"#,
        #"\b\d{1,4}\s?(?:\(\d{1,5}\))?[,:]\s?[A-Za-z]?\d{1,6}\s?[–\-]\s?[A-Za-z]?\d{1,6}\b"#,
    ].joined(separator: "|"), [])

    private static let figureRegex = rx(#"\b(?:Fig(?:ure)?s?\.?)\s*(\d{1,2})(?:[a-z]{1,2})?\b(?:\s*[–\-]\s*(\d{1,2})\b)?"#)
    private static let figureListRegex = rx(#"\s*(?:,|and|&)\s*(\d{1,2})(?:[a-z]{1,2})?\b(?:\s*[–\-]\s*(\d{1,2})\b)?"#)
    private static let figurePrefixExclusion = rx(#"(?:extended\s+data|supplementary|supplemental|suppl?\.|appendix)\s*$"#)
    private static let benchmarkRegex = rx(#"benchmark"#)
    private static let extendedDataMention = rx(#"\bExtended\s+Data\s+(?:Fig(?:ure)?s?\.?|Tables?)\s*\d"#, [])
    private static let supplementaryMention = rx(#"\bsupplement(?:ary|al)\s+(?:fig(?:ure)?s?\.?|tables?|notes?|data|information|materials?|methods|videos?|movies?|text|files?)\b"#)
    private static let supplementaryFigureS = rx(#"\b(?:Fig(?:ure)?s?\.?|Tables?)\s*S\d"#, [])
}
