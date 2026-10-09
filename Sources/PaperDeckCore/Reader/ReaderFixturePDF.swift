import CoreGraphics
import Foundation

/// A synthetic PDF for the reader's tests and `--render` (never used by the reader itself): plain
/// Helvetica text lines and grey "figure" boxes, plus a /PageLabels tree — which Core Graphics' PDF
/// context can't write — so printed labels ("ii", "1203") can be checked against physical pages.
/// Text is ASCII. Owned by Slice C (reader).
package enum ReaderFixturePDF {
    package struct Page: Sendable {
        /// (text, point size), top-down from y = 730 on a US-Letter page.
        package var lines: [(String, CGFloat)]
        /// Filled grey rectangles with a dark outline, in page space.
        package var figures: [CGRect]

        package init(lines: [(String, CGFloat)], figures: [CGRect] = []) { self.lines = lines; self.figures = figures }
    }

    /// One /PageLabels range: from physical page `from` (1-based) on, style "D" (decimal), "r" / "R"
    /// (roman) or "a" / "A" (letters), starting at `start`, with an optional prefix ("S").
    package struct LabelRange: Sendable {
        package var from: Int
        package var style: String?
        package var start: Int
        package var prefix: String?

        package init(from: Int, style: String?, start: Int = 1, prefix: String? = nil) {
            self.from = from; self.style = style; self.start = start; self.prefix = prefix
        }
    }

    package static let pageSize = CGSize(width: 612, height: 792)
    /// The line height the text is laid out with (size × this).
    static let leading: CGFloat = 1.6

    package static func make(pages: [Page], labels: [LabelRange] = []) -> Data {
        var objects: [String] = []                         // object n is objects[n - 1]
        let pageObjectNumbers = pages.indices.map { 4 + $0 * 2 }
        var catalog = "<< /Type /Catalog /Pages 2 0 R"
        if !labels.isEmpty {
            let nums = labels.sorted { $0.from < $1.from }.map { r -> String in
                var d = "<<"
                if let s = r.style { d += " /S /\(s)" }
                if r.start != 1 { d += " /St \(r.start)" }
                if let p = r.prefix { d += " /P (\(escape(p)))" }
                return "\(max(r.from, 1) - 1) \(d) >>"
            }
            catalog += " /PageLabels << /Nums [\(nums.joined(separator: " "))] >>"
        }
        objects.append(catalog + " >>")
        objects.append("<< /Type /Pages /Kids [\(pageObjectNumbers.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        for (i, page) in pages.enumerated() {
            var content = ""
            for f in page.figures {
                content += "q 0.85 g \(n(f.minX)) \(n(f.minY)) \(n(f.width)) \(n(f.height)) re f "
                content += "0.2 G 1.5 w \(n(f.minX)) \(n(f.minY)) \(n(f.width)) \(n(f.height)) re S Q\n"
            }
            var y: CGFloat = 730
            for (text, size) in page.lines {
                content += "BT /F1 \(n(size)) Tf 54 \(n(y)) Td (\(escape(text))) Tj ET\n"
                y -= size * leading
            }
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(pageSize.width)) \(n(pageSize.height))] "
                           + "/Resources << /Font << /F1 3 0 R >> >> /Contents \(pageObjectNumbers[i] + 1) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
        }
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    // MARK: The sample paper

    /// The quote the sample paper prints on physical page 3, broken across two lines with a hyphen.
    package static let sampleQuote = "We regularize the attention weights by a sparsity prior"
    /// Physical page of `sampleQuote`.
    package static let sampleQuotePage = 3
    /// The figure box on physical page 4 (page space).
    package static let sampleFigure = CGRect(x: 72, y: 260, width: 300, height: 180)
    /// Six pages: two front-matter pages labelled "i", "ii", then pages printed 1201–1204 (a journal
    /// reprint). "attention" is printed whole on pages 1, 2, 5 and 6, and broken across two lines on
    /// page 3 ("atten-" / "tion", inside `sampleQuote`).
    package static func sample(title: String = "A Synthetic Paper for the PaperDeck Reader") -> Data {
        let body = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt."
        let pages: [Page] = [
            Page(lines: [(title, 20), ("Ada Example and Grace Sample", 11), ("Abstract", 13),
                         ("We study how attention spreads across a long document.", 10)] + Array(repeating: (body, 10), count: 6)),
            Page(lines: [("Contents", 13), ("1 Introduction ........ 1201", 10), ("2 Methods ........ 1202", 10),
                         ("Attention is all we read.", 10)] + Array(repeating: (body, 10), count: 4)),
            Page(lines: [("1 Introduction", 13)] + Array(repeating: (body, 10), count: 3)
                 + [("To keep the model honest, we regularize the atten-", 10), ("tion weights by a sparsity prior and report", 10),
                    ("the effect in Figure 1.", 10)] + Array(repeating: (body, 10), count: 3)),
            Page(lines: [("2 Methods", 13), ("Figure 1. A grey box standing in for a figure.", 10)] + Array(repeating: (body, 10), count: 2),
                 figures: [sampleFigure]),
            Page(lines: [("3 Results", 13), ("The attention maps agree with the annotations.", 10)] + Array(repeating: (body, 10), count: 5)),
            Page(lines: [("References", 13), ("[1] Vaswani et al. Attention is all you need. 2017.", 10)]),
        ]
        return make(pages: pages, labels: [LabelRange(from: 1, style: "r"), LabelRange(from: 3, style: "D", start: 1201)])
    }

    private static func n(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", Double(v))
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars where c.isASCII {
            switch c {
            case "\\": out += "\\\\"
            case "(": out += "\\("
            case ")": out += "\\)"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }
}
