import Foundation
import PDFKit

/// Printed page labels (DQ §6.5): citations count physical pages (the `[[p. N]]` markers), while a
/// journal PDF may print "1203" on its first page. Synchronous PDFKit inside `PDFKitGate`: call from
/// `BlockingIO.run`.
package enum QAPageLabels {
    /// The label of each of `pages` (1-based physical pages) that has one differing from its number.
    /// An unreadable or locked PDF gives none.
    package static func labels(pdf url: URL, pages: Set<Int>) -> [Int: String] {
        guard !pages.isEmpty, let doc = GatedPDFDocument(url: url) else { return [:] }
        return doc.with { d in
            guard !d.isLocked else { return [:] }
            var out: [Int: String] = [:]
            for n in pages where n >= 1 && n <= d.pageCount {
                guard let label = d.page(at: n - 1)?.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty, label != String(n), label.count <= 16 else { continue }
                out[n] = label
            }
            return out
        }
    }

    /// The PDF's page texts joined by form feeds (the text cache's layout), for a paper whose text
    /// cache is empty. Only `PDFPage.string`, one page per turn at `PDFKitGate`: no title heuristics,
    /// fonts, outline or thumbnail. A locked, unreadable or missing PDF gives "".
    package static func pageText(pdf url: URL) -> String {
        guard let doc = GatedPDFDocument(url: url) else { return "" }
        let count = doc.with { d -> Int in
            if d.isLocked { _ = d.unlock(withPassword: "") }
            return d.isLocked ? 0 : d.pageCount
        }
        guard count > 0 else { return "" }
        var pages: [String] = []
        pages.reserveCapacity(count)
        for i in 0..<count {
            pages.append(doc.with { $0.page(at: i)?.string ?? "" })
        }
        return pages.joined(separator: "\u{0C}")
    }
}
