import CoreGraphics
import Foundation
import NaturalLanguage

/// OCR lines → reading order and clean paragraphs (LN §4.5, dive-capture §4), pure and tested on
/// synthetic line fixtures. Also normalizes exact copied text (Services, the clipboard) the same way.
///
/// Layout (the fallback request's lines; RecognizeDocumentsRequest already groups paragraphs):
/// 1. Column gutters: an x-run at least `gutterWidth` × the median line height wide that lines of at
///    most `gutterCrossShare` of the total line height cross, with text on both sides.
/// 2. Fragments of one visual line (|Δ mid-y| < `sameLine` × h) merge left to right.
/// 3. Paragraph breaks: a gap larger than the usual one by `paragraphGap` × h, a first-line indent
///    over `indent` × h, or a short previous line ending a sentence.
/// 4. A lone page number at a column's top or bottom is dropped.
/// Joining: de-hyphenation with TextPreparer's rule (`(\w)-\n(\p{Ll})` joins) plus a compound guard,
/// CJK lines join without a space, ligatures and full-width Latin letters / digits fold.
package enum OCRPostProcess {
    package struct Tuning: Sendable, Equatable {
        /// Minimum gutter width, in median line heights.
        package var gutterWidth: CGFloat = 1.0
        /// Lines crossing a gutter may add up to this share of all lines' height (spanning titles).
        package var gutterCrossShare: CGFloat = 0.3
        /// Each side of a gutter holds at least this share of all lines' height.
        package var gutterSideShare: CGFloat = 0.15
        /// Fragments with |Δ mid-y| below this many line heights are one visual line.
        package var sameLine: CGFloat = 0.5
        /// A paragraph break: the gap exceeds the column's median gap by this many line heights.
        package var paragraphGap: CGFloat = 0.6
        /// A first-line indent of more than this many line heights starts a paragraph.
        package var indent: CGFloat = 1.0
        /// A previous line ending this many line heights short of the column's right edge (with
        /// sentence-final punctuation) ends a paragraph.
        package var shortLine: CGFloat = 3.0

        package init() {}
    }

    // MARK: - Assembly

    /// The fallback path: raw line observations (any order) → columns, visual lines, paragraphs.
    package static func assemble(_ raw: [OCRLine], imageSize: CGSize, tuning: Tuning = Tuning()) -> OCRResult {
        let cleaned = raw.compactMap { l -> OCRLine? in
            var l = l
            l.text = cleanLine(l.text)
            l.box = l.box.standardized
            return l.text.isEmpty || l.box.width <= 0 || l.box.height <= 0 ? nil : l
        }
        guard !cleaned.isEmpty else { return .empty }
        let h = median(cleaned.map(\.box.height))
        let gutters = self.gutters(cleaned, lineHeight: h, tuning: tuning)
        // Column of each fragment (-1: spans a gutter).
        func column(of box: CGRect) -> Int {
            var col = 0
            for g in gutters {
                if box.maxX <= g.lowerBound + 0.5 { return col }
                if box.minX < g.upperBound - 0.5 { return -1 }
                col += 1
            }
            return col
        }
        let columnCount = gutters.count + 1
        var byColumn = [[OCRLine]](repeating: [], count: columnCount)
        var spanning: [OCRLine] = []
        for l in cleaned {
            let c = column(of: l.box)
            if c < 0 { spanning.append(l) } else { byColumn[c].append(l) }
        }
        // Reading order: bands between spanning lines (top to bottom); inside a band, the
        // columns left to right.
        let spans = mergeVisualLines(spanning, lineHeight: h, tuning: tuning)
        let columns = byColumn.map { mergeVisualLines($0, lineHeight: h, tuning: tuning) }
        var groups: [(lines: [OCRLine], column: Int)] = []
        var cursor = [Int](repeating: 0, count: columnCount)
        let stops: [OCRLine?] = spans.map { Optional($0) } + [nil]
        for s in stops {
            let limit = s?.box.midY ?? .infinity
            for c in 0..<columnCount {
                var band: [OCRLine] = []
                while cursor[c] < columns[c].count, columns[c][cursor[c]].box.midY < limit {
                    band.append(columns[c][cursor[c]])
                    cursor[c] += 1
                }
                if !band.isEmpty { groups.append((band, c)) }
            }
            guard let s else { continue }
            // Consecutive spanning lines (a two-line title) stay one group.
            if let last = groups.last, last.column == -1 {
                groups[groups.count - 1].lines.append(s)
            } else {
                groups.append(([s], -1))
            }
        }
        var paragraphs: [[OCRLine]] = []
        var paragraphColumns: [Int] = []
        for g in groups {
            let lines = g.column >= 0 ? dropFurniture(g.lines, lineHeight: h) : g.lines
            for p in splitParagraphs(lines, lineHeight: h, tuning: tuning) {
                paragraphs.append(p)
                paragraphColumns.append(g.column)
            }
        }
        return build(paragraphs, columns: paragraphColumns)
    }

    /// The document path: Vision's paragraphs (reading order kept), each a list of lines.
    package static func assemble(paragraphs: [[OCRLine]]) -> OCRResult {
        let cleaned = paragraphs.map { p in
            p.compactMap { l -> OCRLine? in
                var l = l
                l.text = cleanLine(l.text)
                l.box = l.box.standardized
                return l.text.isEmpty ? nil : l
            }
        }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return .empty }
        let all = cleaned.flatMap { $0 }
        let h = median(all.map(\.box.height))
        let gutters = self.gutters(all, lineHeight: h, tuning: Tuning())
        let cols = cleaned.map { p -> Int in
            let box = p.map(\.box).reduce(CGRect.null) { $0.union($1) }
            var col = 0
            for g in gutters {
                if box.maxX <= g.lowerBound + 0.5 { return col }
                if box.minX < g.upperBound - 0.5 { return -1 }
                col += 1
            }
            return col
        }
        return build(cleaned, columns: cols)
    }

    private static func build(_ paragraphs: [[OCRLine]], columns: [Int]) -> OCRResult {
        var lines: [OCRLine] = []
        var out: [OCRParagraph] = []
        for (i, p) in paragraphs.enumerated() {
            let text = join(p.map(\.text))
            guard !text.isEmpty else { continue }
            let start = lines.count
            lines += p
            let box = p.map(\.box).reduce(CGRect.null) { $0.union($1) }
            out.append(OCRParagraph(text: text, box: box, lineIndices: Array(start..<lines.count), column: columns[i]))
        }
        let mean = lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
        return OCRResult(lines: lines, paragraphs: out, text: out.map(\.text).joined(separator: "\n\n"),
                         meanConfidence: min(max(mean, 0), 1))
    }

    // MARK: - Columns

    /// The x-ranges of the column gutters, left to right (empty: one column).
    package static func gutters(_ lines: [OCRLine], lineHeight h: CGFloat, tuning: Tuning = Tuning()) -> [ClosedRange<CGFloat>] {
        guard lines.count >= 2, h > 0 else { return [] }
        let minX = lines.map(\.box.minX).min()!, maxX = lines.map(\.box.maxX).max()!
        let bin = max(1, h / 4)
        let n = Int(((maxX - minX) / bin).rounded(.up))
        guard n >= 3 else { return [] }
        var cross = [CGFloat](repeating: 0, count: n)
        for l in lines {
            let a = max(0, Int(((l.box.minX - minX) / bin).rounded(.down)))
            let b = min(n - 1, Int(((l.box.maxX - minX) / bin).rounded(.up)) - 1)
            if a <= b { for i in a...b { cross[i] += l.box.height } }
        }
        let total = lines.reduce(0) { $0 + $1.box.height }
        var out: [ClosedRange<CGFloat>] = []
        var i = 0
        while i < n {
            guard cross[i] <= tuning.gutterCrossShare * total else { i += 1; continue }
            var j = i
            while j + 1 < n, cross[j + 1] <= tuning.gutterCrossShare * total { j += 1 }
            let lo = minX + CGFloat(i) * bin, hi = minX + CGFloat(j + 1) * bin
            if hi - lo >= tuning.gutterWidth * h {
                let left = lines.filter { $0.box.maxX <= lo + 0.5 }.reduce(0) { $0 + $1.box.height }
                let right = lines.filter { $0.box.minX >= hi - 0.5 }.reduce(0) { $0 + $1.box.height }
                if left >= tuning.gutterSideShare * total, right >= tuning.gutterSideShare * total {
                    out.append(lo...hi)
                }
            }
            i = j + 1
        }
        return out
    }

    // MARK: - Lines and paragraphs

    /// Fragments of one visual line merged left to right, lines sorted top to bottom.
    package static func mergeVisualLines(_ lines: [OCRLine], lineHeight h: CGFloat, tuning: Tuning = Tuning()) -> [OCRLine] {
        let sorted = lines.sorted { $0.box.midY != $1.box.midY ? $0.box.midY < $1.box.midY : $0.box.minX < $1.box.minX }
        var groups: [[OCRLine]] = []
        for l in sorted {
            if var last = groups.last, let ref = last.first,
               abs(l.box.midY - ref.box.midY) < tuning.sameLine * max(h, 1),
               !last.contains(where: { horizontalOverlap($0.box, l.box) > 0.5 * min($0.box.width, l.box.width) }) {
                last.append(l)
                groups[groups.count - 1] = last
            } else {
                groups.append([l])
            }
        }
        return groups.map { g in
            let parts = g.sorted { $0.box.minX < $1.box.minX }
            guard parts.count > 1 else { return parts[0] }
            var text = parts[0].text
            for p in parts.dropFirst() { text = joinFragments(text, p.text) }
            let box = parts.map(\.box).reduce(CGRect.null) { $0.union($1) }
            let conf = parts.map(\.confidence).reduce(0, +) / Double(parts.count)
            return OCRLine(text: text, box: box, confidence: conf, words: parts.flatMap(\.words))
        }
    }

    /// One column's visual lines (top to bottom) split into paragraphs.
    package static func splitParagraphs(_ lines: [OCRLine], lineHeight h: CGFloat, tuning: Tuning = Tuning()) -> [[OCRLine]] {
        guard let first = lines.first else { return [] }
        guard lines.count > 1 else { return [[first]] }
        let left = lines.map(\.box.minX).min()!, right = lines.map(\.box.maxX).max()!
        let gaps = zip(lines, lines.dropFirst()).map { $1.box.minY - $0.box.maxY }
        let usual = median(gaps.map { max($0, 0) })
        var out: [[OCRLine]] = [[first]]
        for (i, l) in lines.enumerated().dropFirst() {
            let prev = lines[i - 1]
            let gap = gaps[i - 1]
            let indented = l.box.minX - left > tuning.indent * h && prev.box.minX - left < 0.5 * h
            let short = prev.box.maxX < right - tuning.shortLine * h && endsSentence(prev.text)
            if gap > usual + tuning.paragraphGap * h || indented || short {
                out.append([l])
            } else {
                out[out.count - 1].append(l)
            }
        }
        return out
    }

    /// A lone number (a page number) as a column's first or last line of three or more, set apart
    /// from its neighbour by at least half a line (an exponent or an index sitting on its line stays).
    private static func dropFurniture(_ lines: [OCRLine], lineHeight h: CGFloat) -> [OCRLine] {
        guard lines.count >= 3 else { return lines }
        var out = lines
        if let last = out.last, isLoneNumber(last.text), last.box.minY - out[out.count - 2].box.maxY >= 0.5 * h {
            out.removeLast()
        }
        if let first = out.first, isLoneNumber(first.text), out[1].box.minY - first.box.maxY >= 0.5 * h {
            out.removeFirst()
        }
        return out
    }

    private static func isLoneNumber(_ s: String) -> Bool {
        s.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil
    }

    private static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".:?!。：？！".contains(last)
    }

    // MARK: - Joining

    /// Visual lines → one paragraph: TextPreparer's de-hyphenation (a word character, a hyphen at
    /// the line end and a lowercase start join with the hyphen dropped) unless the left part is a
    /// compound (`keepsHyphen`); a hyphen before a digit / capital stays and joins ("COVID-19");
    /// CJK on either side joins without a space; otherwise one space.
    package static func join(_ lines: [String]) -> String {
        var out = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            out = out.isEmpty ? line : joinLines(out, line)
        }
        return out
    }

    private static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{00AD}"]

    private static func joinLines(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return left + right }
        if hyphens.contains(last), left.count >= 2 {
            let before = left[left.index(left.endIndex, offsetBy: -2)]
            if isWordCharacter(before) {
                let stem = String(left.dropLast())
                if first.isLowercase {
                    if last == "\u{00AD}" { return stem + right }                  // a soft hyphen always goes
                    return keepsHyphen(stem) ? stem + "-" + right : stem + right
                }
                if first.isNumber || first.isUppercase { return stem + "-" + right }
            }
        }
        if isCJK(last) || isCJK(first) { return left + right }
        return left + " " + right
    }

    /// Two fragments of the same visual line.
    private static func joinFragments(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return left + right }
        return isCJK(last) || isCJK(first) ? left + right : left + " " + right
    }

    /// Compound prefixes whose line-end hyphen is part of the word ("self-supervised",
    /// "high-throughput", "single-cell"); an already hyphenated left part ("state-of-the-",
    /// "end-to-") keeps it too.
    package static let compoundPrefixes: Set<String> = [
        "self", "cross", "well", "high", "low", "long", "short", "large", "small", "real", "end", "fine",
        "single", "double", "two", "three", "four", "five", "first", "second", "third", "half", "full",
    ]

    package static func keepsHyphen(_ stem: String) -> Bool {
        var token = ""
        for ch in stem.reversed() {
            guard ch.isLetter || ch == "-" else { break }
            token.insert(ch, at: token.startIndex)
        }
        let word = token.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
        return word.contains("-") || compoundPrefixes.contains(word)
    }

    /// TextPreparer's rule (`(\w)-\n(\p{Ll})` → `$1$2`) on multi-line text, with the compound guard.
    package static func dehyphenate(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in hyphenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let stem = ns.substring(with: NSRange(location: 0, length: m.range.location + 1))
            let left = ns.substring(with: m.range(at: 1)), right = ns.substring(with: m.range(at: 2))
            out += keepsHyphen(stem) ? left + "-" + right : left + right
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// TextPreparer's own pattern (R-CAP-4: one rule, not a copy).
    private static let hyphenRegex = try! NSRegularExpression(pattern: TextPreparer.hyphenPattern)

    // MARK: - Characters

    /// Han, kana and CJK / full-width punctuation: joined without spaces (Hangul uses spaces).
    package static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { u in
            switch u.value {
            case 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x31FF, 0x3200...0x33FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF0F,
                 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65, 0x20000...0x3FFFF:
                return true
            default:
                return false
            }
        }
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    /// Ligatures (ﬁ ﬂ ﬀ ﬃ ﬄ ﬅ ﬆ) and full-width Latin letters / digits folded; full-width CJK
    /// punctuation, superscripts and every other symbol stay as they are (NFKC would turn x² into x2).
    package static func foldLigatures(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0xFB00...0xFB06).contains($0.value) || (0xFF10...0xFF5A).contains($0.value) })
        else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0xFB00: out.append(contentsOf: "ff".unicodeScalars)
            case 0xFB01: out.append(contentsOf: "fi".unicodeScalars)
            case 0xFB02: out.append(contentsOf: "fl".unicodeScalars)
            case 0xFB03: out.append(contentsOf: "ffi".unicodeScalars)
            case 0xFB04: out.append(contentsOf: "ffl".unicodeScalars)
            case 0xFB05, 0xFB06: out.append(contentsOf: "st".unicodeScalars)
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                out.append(Unicode.Scalar(u.value - 0xFEE0)!)
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// One OCR line: ligatures folded, invisible marks dropped (a line-final soft hyphen stays: it
    /// marks a break inside a word for `join`), any whitespace one space, trimmed.
    package static func cleanLine(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        let softEnd = s.unicodeScalars.last(where: { !$0.properties.isWhitespace }) == "\u{00AD}"
        for u in foldLigatures(s).unicodeScalars {
            if u.properties.generalCategory == .format || u.properties.generalCategory == .control && !u.properties.isWhitespace {
                continue
            }
            if u.properties.isWhitespace {
                space = !out.isEmpty
                continue
            }
            if space { out.append(" "); space = false }
            out.append(u)
        }
        if softEnd, !out.isEmpty { out.append("\u{00AD}") }
        return String(out)
    }

    /// Exact copied text (Services, the clipboard): line breaks unified, ligatures folded,
    /// de-hyphenated, single line breaks unwrapped (CJK without a space), blank-line paragraph
    /// breaks kept, trimmed.
    package static func normalizeCopied(_ raw: String) -> String {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n\n")
        let blocks = unified.components(separatedBy: "\n").reduce(into: [[String]]([[]])) { acc, line in
            let clean = cleanLine(line)
            if clean.isEmpty {
                if !(acc.last?.isEmpty ?? true) { acc.append([]) }
            } else {
                acc[acc.count - 1].append(clean)
            }
        }
        return blocks.filter { !$0.isEmpty }.map(join).joined(separator: "\n\n")
    }

    // MARK: - Hit testing

    /// The paragraph under `point` (image pixels): the one whose box contains it, else the nearest
    /// within 1.5 line heights; nil when the click is on nothing.
    package static func block(at point: CGPoint, in r: OCRResult) -> OCRParagraph? {
        guard !r.paragraphs.isEmpty else { return nil }
        if let hit = r.paragraphs.first(where: { $0.box.contains(point) }) { return hit }
        let h = max(r.medianLineHeight, 1)
        let near = r.paragraphs.map { ($0, distance($0.box, point)) }.min { $0.1 < $1.1 }
        guard let near, near.1 <= 1.5 * h else { return nil }
        return near.0
    }

    /// The sides of a capture.
    package struct Edges: OptionSet, Sendable, Hashable {
        package let rawValue: Int
        package init(rawValue: Int) { self.rawValue = rawValue }
        package static let top = Edges(rawValue: 1)
        package static let left = Edges(rawValue: 2)
        package static let bottom = Edges(rawValue: 4)
        package static let right = Edges(rawValue: 8)
        package static let all: Edges = [.top, .left, .bottom, .right]
    }

    /// The block runs into one of the capture's `edges` (within `margin` pixels): a click's paragraph
    /// is then read once more from the larger area the capture holds (`ExplainFocusResolver.read`,
    /// LN §4.4), so it isn't cut off.
    package static func isCutOff(_ p: OCRParagraph, imageSize: CGSize, margin: CGFloat = 2, edges: Edges = .all) -> Bool {
        edges.contains(.left) && p.box.minX <= margin || edges.contains(.top) && p.box.minY <= margin
            || edges.contains(.right) && p.box.maxX >= imageSize.width - margin
            || edges.contains(.bottom) && p.box.maxY >= imageSize.height - margin
    }

    /// `r` (read from a part of an image) moved by `origin` — the part's top-left in the image —
    /// into the image's pixels: every line, word and paragraph box.
    package static func offset(_ r: OCRResult, by origin: CGPoint) -> OCRResult {
        guard origin != .zero else { return r }
        func move(_ b: CGRect) -> CGRect { b.offsetBy(dx: origin.x, dy: origin.y) }
        var out = r
        out.lines = r.lines.map { l in
            var l = l
            l.box = move(l.box)
            l.words = l.words.map { OCRWord(text: $0.text, box: move($0.box)) }
            return l
        }
        out.paragraphs = r.paragraphs.map { p in
            var p = p
            p.box = move(p.box)
            return p
        }
        return out
    }

    /// The word under `point` (image pixels): the recognized word's box, else the line's text split
    /// evenly by characters. Surrounding punctuation is trimmed; CJK text (no spaces between words)
    /// is segmented with NLTokenizer and the word holding the point is taken (CUX-11) — a run of
    /// Chinese in one word box is segmented the same way. nil off any line.
    package static func word(at point: CGPoint, in r: OCRResult) -> String? {
        let h = max(r.medianLineHeight, 1)
        guard let line = r.lines.first(where: { $0.box.insetBy(dx: -0.25 * h, dy: -0.2 * h).contains(point) }) else { return nil }
        if !line.words.isEmpty {
            guard let w = line.words.first(where: { $0.box.contains(point) })
                    ?? line.words.min(by: { distance($0.box, point) < distance($1.box, point) }) else { return nil }
            if w.text.count > 2, w.text.contains(where: isCJK), w.box.width > 0 {
                let chars = Array(w.text)
                let fraction = min(max((point.x - w.box.minX) / w.box.width, 0), 0.9999)
                return cjkWord(in: w.text, at: Int(fraction * CGFloat(chars.count)))
            }
            let token = trimPunctuation(w.text)
            return token.isEmpty ? nil : token
        }
        let chars = Array(line.text)
        guard !chars.isEmpty, line.box.width > 0 else { return nil }
        let fraction = min(max((point.x - line.box.minX) / line.box.width, 0), 0.9999)
        let index = Int(fraction * CGFloat(chars.count))
        // A line with Chinese / Japanese has no spaces between words (a Latin word inside it either).
        if chars.contains(where: { isCJK($0) && $0.isLetter }) { return cjkWord(in: line.text, at: index) }
        var lo = index, hi = index
        while lo > 0, !chars[lo - 1].isWhitespace { lo -= 1 }
        while hi < chars.count, !chars[hi].isWhitespace { hi += 1 }
        let token = trimPunctuation(String(chars[lo..<hi]))
        return token.isEmpty ? nil : token
    }

    /// The word of `text` (Chinese / Japanese, possibly mixed with Latin) holding character `index`:
    /// NLTokenizer's segmentation, so a click on 机 in 注意力机制… gives a whole word (机制), never a
    /// fixed window that cuts terms (力机制使). Punctuation under the click takes the nearest word.
    package static func cjkWord(in text: String, at index: Int) -> String? {
        let chars = Array(text)
        guard chars.indices.contains(index) else { return nil }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if text.contains(where: { isCJK($0) && !$0.isPunctuation }) { tokenizer.setLanguage(.simplifiedChinese) }
        var words: [(range: Range<Int>, text: String)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let lo = text.distance(from: text.startIndex, to: range.lowerBound)
            let hi = text.distance(from: text.startIndex, to: range.upperBound)
            words.append((lo..<hi, String(text[range])))
            return true
        }
        let pick = words.first { $0.range.contains(index) }
            ?? words.min { abs(($0.range.lowerBound + $0.range.upperBound) / 2 - index) < abs(($1.range.lowerBound + $1.range.upperBound) / 2 - index) }
        guard let pick else { return nil }
        let token = trimPunctuation(pick.text)
        return token.isEmpty ? nil : token
    }

    private static func trimPunctuation(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces).union(.symbols)
            .subtracting(CharacterSet(charactersIn: "-")))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Helpers

    package static func median(_ xs: [CGFloat]) -> CGFloat {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
