import AppKit
import Foundation
@preconcurrency import PDFKit

/// Local title guesses (§6.1): the largest-font run on page 1 (right 4 of 5 times on the
/// user's papers), and the PDF Title attribute once junk like "Microsoft Word - x.docx" is removed.
package enum TitleHeuristic {

    /// One run of same-size text on page 1. `top` is the run's upper edge in page space
    /// (PDF origin bottom-left); nil when PDFKit can't locate it.
    package struct FontRun: Sendable, Equatable {
        package var text: String
        package var pointSize: Double
        package var top: Double?

        package init(text: String, pointSize: Double, top: Double?) {
            self.text = text; self.pointSize = pointSize; self.top = top
        }
    }

    /// Largest plausible run whose top lies in the upper 65% of the page.
    package static func pick(runs: [FontRun], pageMinY: Double = 0, pageHeight: Double) -> String? {
        choose(runs.map { ($0.text, $0.pointSize) }, pageMinY: pageMinY, pageHeight: pageHeight) { runs[$0].top }
    }

    /// Reads font runs from page 1 of a document the caller owns, inside `PDFKitGate` (re-entrant:
    /// the extractor calls it holding the gate already). `attributedString` is the call PDFKit
    /// crashed in under concurrency (Phase 2 fix QA-15). A title-only lock didn't stop that; one gate
    /// around every PDFKit path does (see `PDFKitGate`). It runs once per imported PDF, for page 1
    /// only.
    static func title(of page: PDFPage) -> String? {
        PDFKitGate.shared.run { fontRunTitle(of: page) }
    }

    /// The former title-only gate (request R-QAF-3), now the process-wide `PDFKitGate`.
    package typealias FontRunGate = PDFKitGate

    /// PDFKit's attributed text of `page`, or nil when PDFKit throws building it (R-PDFKIT-2). The
    /// gate can't cover a reader window's PDFView, which draws on PDFKit's own threads; racing that,
    /// PDFKit can still throw "object cannot be nil (key: NSFont)". The font-run title is then
    /// skipped (the Title attribute or the file name wins) instead of the process aborting. Only
    /// the one call is wrapped: the gate and the autorelease pool stay outside the catch.
    static func attributedText(of page: PDFPage) -> NSAttributedString? {
        switch ObjCException.catching({ page.attributedString }) {
        case .success(let text):
            return text
        case .failure(let exception):
            Thread.current.threadDictionary[caughtKey] = exceptionsCaughtOnThisThread + 1
            Log.importer.error("title: PDFKit threw \(exception.name, privacy: .public) building page 1's text; font-run title skipped")
            return nil
        }
    }

    /// How many PDFKit exceptions `attributedText(of:)` caught on the calling thread. With every
    /// PaperDeck path inside the gate PDFKit shouldn't throw at all: `PDFKitGateStressTests` (opt-in)
    /// checks its worker threads saw none, so a path that slips out of the gate still fails it.
    package static var exceptionsCaughtOnThisThread: Int { (Thread.current.threadDictionary[caughtKey] as? Int) ?? 0 }
    private static let caughtKey = "PaperDeck.TitleHeuristic.caughtPDFKitExceptions"

    private static func fontRunTitle(of page: PDFPage) -> String? {
        guard let attributed = attributedText(of: page), attributed.length > 0 else { return nil }
        let string = attributed.string as NSString
        var groups: [(text: String, size: Double, range: NSRange)] = []
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let piece = string.substring(with: range)
            let adjacent = groups.last.map { NSMaxRange($0.range) == range.location } ?? false
            // Whitespace between title lines may carry another font; it never splits a run.
            if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if adjacent { groups[groups.count - 1].text += piece; groups[groups.count - 1].range.length += range.length }
                return
            }
            guard let font = value as? NSFont else { return }
            let size = Double(font.pointSize)
            if adjacent, let last = groups.last, abs(last.size - size) < 0.6 {
                groups[groups.count - 1].text += piece
                groups[groups.count - 1].range.length += range.length
            } else {
                groups.append((piece, size, range))
            }
        }
        let box = page.bounds(for: .cropBox)
        return choose(groups.map { ($0.text, $0.size) }, pageMinY: Double(box.minY), pageHeight: Double(box.height)) { i in
            // selection(for:) is the expensive part, so it runs only for plausible candidates.
            page.selection(for: groups[i].range).map { Double($0.bounds(for: page).maxY) }
        }
    }

    /// Cleans the PDF Title attribute; nil for junk (`doi:…`, "Untitled", "Microsoft Word - …",
    /// "Document1", file names), anything under 10 characters, or a single token.
    package static func cleanAttributeTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = normalize(raw)
        guard t.count >= 10, t.contains(" "),
              junkAttributeRegex.firstMatch(in: t, range: fullRange(t)) == nil else { return nil }
        return t
    }

    /// Journal labels, licence lines, arXiv stamps and URLs that often use a large font.
    package static func isBoilerplate(_ s: String) -> Bool {
        boilerplateRegex.firstMatch(in: s, range: fullRange(s)) != nil
    }

    /// 12–300 characters, ≥ 3 words or ≥ 6 CJK characters, mostly letters, not boilerplate.
    package static func isPlausibleTitle(_ s: String) -> Bool {
        guard (12...300).contains(s.count), !isBoilerplate(s) else { return false }
        var letters = 0, cjk = 0, visible = 0
        for u in s.unicodeScalars where !u.properties.isWhitespace {
            visible += 1
            if u.properties.isAlphabetic { letters += 1 }
            if isCJK(u) { cjk += 1 }
        }
        guard visible > 0, Double(letters) / Double(visible) >= 0.5 else { return false }
        return s.split(separator: " ").count >= 3 || cjk >= 6
    }

    /// Equal ignoring case, punctuation and spacing.
    package static func sameWords(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }))
        }
        let ka = key(a)
        return !ka.isEmpty && ka == key(b)
    }

    /// Collapses whitespace and line breaks; a line-end hyphen keeps its hyphen ("Single-\ncell").
    package static func normalize(_ s: String) -> String {
        var t = lineHyphenRegex.stringByReplacingMatches(in: s, range: fullRange(s), withTemplate: "$1-$2")
        t = t.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        while let last = t.last, "*†‡§¶".contains(last) || last == " " { t.removeLast() }
        return t
    }

    private static func choose(_ runs: [(text: String, size: Double)], pageMinY: Double, pageHeight: Double,
                               top: (Int) -> Double?) -> String? {
        let threshold = pageMinY + 0.35 * pageHeight
        var order: [(index: Int, text: String, size: Double)] = []
        for (i, run) in runs.enumerated() {
            let text = normalize(run.text)
            if isPlausibleTitle(text) { order.append((i, text, run.size)) }
        }
        // Stable: equal sizes keep reading order.
        order.sort { a, b in a.size != b.size ? a.size > b.size : a.index < b.index }
        for candidate in order.prefix(12) {
            if let y = top(candidate.index), y >= threshold { return candidate.text }
        }
        return nil
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    private static func fullRange(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
        catch { preconditionFailure("TitleHeuristic: bad pattern \(pattern): \(error)") }
    }

    private static let boilerplateRegex = rx(
        #"^(?:article|resource|research(?: article)?|letter|review|report|brief communication|preprint|open access)$"#
        + #"|biorxiv|medrxiv|copyright|©|\bdoi\b|arxiv:|https?://|received|accepted"#)
    // "document\d*" is anchored so real titles starting with "Documenting…" survive.
    private static let junkAttributeRegex = rx(#"^(?:doi:|untitled\b|microsoft word\b|document\d*$)|\.(?:docx?|tex|dvi|pdf)$"#)
    private static let lineHyphenRegex = rx(#"(\p{L})-[ \t]*\R[ \t]*(\p{L})"#)
}
