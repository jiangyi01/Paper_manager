import Foundation

/// Paper text as sent to the agent inside `<paper>…</paper>`.
package struct PreparedText: Sendable, Equatable {
    package var text: String
    package var originalChars: Int          // characters in the raw page texts
    package var omittedChars: Int           // characters cut to fit the budget (Σ N of the "[… N characters …]" markers)
    package var droppedSections: [String]   // e.g. "references", "acknowledgements", "Methods (trimmed)"

    package init(text: String, originalChars: Int, omittedChars: Int, droppedSections: [String]) {
        self.text = text; self.originalChars = originalChars
        self.omittedChars = omittedChars; self.droppedSections = droppedSections
    }
}

/// Turns extracted page text into the agent's `<paper>` payload (§6.2 steps 1–6): page
/// markers, de-hyphenation, running header/footer removal, reference and back-matter removal,
/// budget trimming (supplementary legends first, then the Methods tail), tag escaping.
/// Pure function: the same input always yields the same text.
package enum TextPreparer {

    package static func prepare(pageTexts: [String], structure: DocumentStructure, budget: Int) -> PreparedText {
        let originalChars = pageTexts.reduce(0) { $0 + $1.count }

        // Steps 1–3: per-page lines, de-hyphenated, without running headers/footers.
        var pages = pageTexts.map { page -> [String] in
            let unified = page.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let joined = hyphenRegex.stringByReplacingMatches(in: unified, range: fullRange(unified), withTemplate: "$1$2")
            return joined.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && pageNumberRegex.firstMatch(in: $0, range: fullRange($0)) == nil }
        }
        removeRunningLines(&pages)

        var lines: [Sections.Line] = []
        for (i, page) in pages.enumerated() {
            for text in page { lines.append(Sections.Line(page: i + 1, text: text)) }
        }
        let n = lines.count
        let headings = Sections.classify(lines)
        let refLike = lines.map { Sections.isReferenceLike($0.text) }
        var owners = Sections.owners(lines: lines, headings: headings, refLike: refLike)
        applyOutlineMethods(structure: structure, lines: lines, headings: headings, owner: &owners)
        let owner = owners
        let protectedEnd = protectedPrefixEnd(lines: lines, headings: headings)

        // Step 4: drop reference lists and back matter.
        var state = [LineState](repeating: .keep, count: n)
        var dropped: [String] = []
        func note(_ name: String) { if !dropped.contains(name) { dropped.append(name) } }
        for i in protectedEnd..<n {
            if let o = owner[i], let name = dropName(o) { state[i] = .dropped; note(name) }
        }
        let remaining = (protectedEnd..<n).filter { state[$0] == .keep }
        let mask = Sections.unheadedReferenceMask(refLike: remaining.map { refLike[$0] },
                                                  refStart: remaining.map { Sections.isReferenceStart(lines[$0].text) })
        for (j, i) in remaining.enumerated() where mask[j] { state[i] = .dropped; note("references (unheaded)") }

        // Step 5: fit the budget.
        let lengths = lines.map { $0.text.count + 1 }
        var rendered = render(lines, state)
        if budget > 0, rendered.text.count > budget {
            let passes: [(label: (Int) -> String?, keepHead: Int)] = [
                ({ i in supplementaryLabel(owner[i]) }, 0),
                ({ i in owner[i] == .section(.methods) ? "Methods" : nil }, 1500),
                ({ i in isAvailability(owner[i]) ? nil : "main text" }, 0),
            ]
            for pass in passes {
                let candidates = (protectedEnd..<n).filter { state[$0] == .keep && pass.label($0) != nil }
                let trimmable = Array(candidates.dropFirst(headCount(candidates, lengths: lengths, keep: pass.keepHead)))
                var cursor = trimmable.count
                while rendered.text.count > budget, cursor > 0 {
                    var excess = rendered.text.count - budget + 64      // room for the marker line
                    while excess > 0, cursor > 0 {
                        cursor -= 1
                        let i = trimmable[cursor]
                        if let label = pass.label(i) { state[i] = .trimmed(label); excess -= lengths[i] }
                    }
                    rendered = render(lines, state)
                }
                for i in trimmable[cursor...] {
                    if case .trimmed(let label) = state[i] { note(label + " (trimmed)") }
                }
                if rendered.text.count <= budget { break }
            }
        }

        // Step 6: the payload must not be able to close or open our wrapper tags.
        var text = rendered.text
        text = closedTagRegex.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: "[$1$2$3]")
        text = openTagRegex.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: "[$1$2")

        return PreparedText(text: text, originalChars: originalChars, omittedChars: rendered.omitted, droppedSections: dropped)
    }

    // MARK: Steps

    private enum LineState: Equatable {
        case keep, dropped
        case trimmed(String)
    }

    /// Step 3: with ≥ 4 pages, a line (≤ 80 chars) on ≥ max(3, ⌈pages/2⌉) pages is a running header
    /// or footer. Digits are ignored when comparing ("12 of 28"). Page 1 keeps its lines so the
    /// title survives a running title; preprint licence stamps go everywhere regardless of length.
    private static func removeRunningLines(_ pages: inout [[String]]) {
        guard pages.count >= 4 else { return }
        let threshold = max(3, Int((Double(pages.count) * 0.5).rounded(.up)))
        func key(_ line: String) -> String {
            digitsRegex.stringByReplacingMatches(in: line, range: fullRange(line), withTemplate: "#")
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        func isStamp(_ line: String) -> Bool { stampRegex.firstMatch(in: line, range: fullRange(line)) != nil }
        var pageCounts: [String: Int] = [:]
        for page in pages {
            var seen = Set<String>()
            for line in page where line.count <= 80 || isStamp(line) {
                let k = key(line)
                if seen.insert(k).inserted { pageCounts[k, default: 0] += 1 }
            }
        }
        let repeated = Set(pageCounts.filter { $0.value >= threshold }.keys)
        guard !repeated.isEmpty else { return }
        for p in pages.indices {
            pages[p].removeAll { line in
                guard line.count <= 80 || isStamp(line) else { return false }
                return (p > 0 || isStamp(line)) && repeated.contains(key(line))
            }
        }
    }

    /// Title and abstract are never dropped or trimmed: everything before the heading that
    /// follows "Abstract" (capped at 60 lines and the end of page 2), or all of page 1.
    private static func protectedPrefixEnd(lines: [Sections.Line], headings: [Sections.Heading?]) -> Int {
        let n = lines.count
        let page1End = lines.firstIndex { $0.page >= 2 } ?? n
        guard let a = headings.indices.first(where: { headings[$0] == .section(.abstract) && lines[$0].page <= 2 })
        else { return page1End }
        let page2End = lines.firstIndex { $0.page >= 3 } ?? n
        let next = ((a + 1)..<n).first { headings[$0] != nil } ?? n
        return max(a + 1, min(next, a + 60, page2End))
    }

    /// When the outline found Methods but no text heading did, Methods runs from its page
    /// to the next heading, so the budget step can still trim its tail.
    private static func applyOutlineMethods(structure: DocumentStructure, lines: [Sections.Line],
                                            headings: [Sections.Heading?], owner: inout [Sections.Heading?]) {
        guard structure.sectionsFromOutline, let page = structure.page(of: .methods),
              !owner.contains(.section(.methods)),
              let start = lines.firstIndex(where: { $0.page >= page }) else { return }
        var i = start
        while i < lines.count, i == start || headings[i] == nil {
            owner[i] = .section(.methods)
            i += 1
        }
    }

    private static func dropName(_ h: Sections.Heading) -> String? {
        switch h {
        case .section(.references): return "references"
        case .section(.acknowledgements): return "acknowledgements"
        case .authorContributions: return "author contributions"
        case .competingInterests: return "competing interests"
        case .reportingSummary: return "reporting summary"
        default: return nil
        }
    }

    private static func supplementaryLabel(_ h: Sections.Heading?) -> String? {
        switch h {
        case .section(.extendedData)?, .extendedDataLegend?: return "Extended Data"
        case .section(.supplementary)?, .supplementaryLegend?: return "Supplementary information"
        case .appendix?: return "Appendix"
        default: return nil
        }
    }

    private static func isAvailability(_ h: Sections.Heading?) -> Bool {
        h == .section(.dataAvailability) || h == .section(.codeAvailability)
    }

    /// Number of leading candidates covering `keep` characters (the Methods head stays).
    private static func headCount(_ candidates: [Int], lengths: [Int], keep: Int) -> Int {
        guard keep > 0 else { return 0 }
        var total = 0, count = 0
        for i in candidates where total < keep { total += lengths[i]; count += 1 }
        return count
    }

    /// Joins kept lines with `[[p. N]]` before each page's first output line; consecutive trimmed
    /// lines collapse into one "[… N characters of <label> omitted …]" line.
    private static func render(_ lines: [Sections.Line], _ state: [LineState]) -> (text: String, omitted: Int) {
        var out = ""
        var omitted = 0
        var lastPage = 0
        func mark(_ page: Int) {
            if page != lastPage { out += "[[p. \(page)]]\n"; lastPage = page }
        }
        var i = 0
        while i < lines.count {
            switch state[i] {
            case .dropped:
                i += 1
            case .keep:
                mark(lines[i].page)
                out += lines[i].text
                out += "\n"
                i += 1
            case .trimmed:
                mark(lines[i].page)
                var perLabel: [(label: String, chars: Int)] = []
                var j = i
                while j < lines.count {
                    if state[j] == .dropped { j += 1; continue }
                    guard case .trimmed(let label) = state[j] else { break }
                    let chars = lines[j].text.count + 1
                    if let k = perLabel.firstIndex(where: { $0.label == label }) { perLabel[k].chars += chars }
                    else { perLabel.append((label, chars)) }
                    j += 1
                }
                let chars = perLabel.reduce(0) { $0 + $1.chars }
                // A contiguous cut gets one marker, named after the section contributing most.
                let label = perLabel.max { $0.chars < $1.chars }?.label ?? "text"
                out += "[… \(chars) characters of \(label) omitted …]\n"
                omitted += chars
                i = j
            }
        }
        return (out, omitted)
    }

    // MARK: Patterns

    private static func fullRange(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: options) }
        catch { preconditionFailure("TextPreparer: bad pattern \(pattern): \(error)") }
    }

    /// A word character, a hyphen at the line end and a lowercase start: joined, the hyphen dropped.
    /// OCR applies the same rule (`OCRPostProcess.dehyphenate`, with its compound guard).
    package static let hyphenPattern = #"(\w)-\n(\p{Ll})"#
    private static let hyphenRegex = rx(hyphenPattern)
    private static let pageNumberRegex = rx(#"^\d{1,4}$"#)
    private static let digitsRegex = rx(#"\d+"#)
    private static let stampRegex = rx(#"copyright holder for this preprint|not certified by peer review|international license|all rights reserved"#,
                                       [.caseInsensitive])
    private static let closedTagRegex = rx(#"<(/?)(paper|metadata|library)\b([^<>\n]{0,200})>"#, [.caseInsensitive])
    private static let openTagRegex = rx(#"<(/?)(paper|metadata|library)\b"#, [.caseInsensitive])
}
