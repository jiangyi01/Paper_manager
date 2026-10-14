import Foundation

/// The Mail inbox list's columns at any window width (pure layout math, so it is testable):
/// one readable column (at most `maxColumn` wide, centred) until a second — later a third — fits
/// at `minColumn` or wider; then the cards flow into balanced columns, newest first in each, by
/// their estimated heights (the shortest column takes the next card), so no column ends far
/// below the others and nothing leaves a ragged hole.
package enum MailInboxLayout {
    package static let minColumn: Double = 700
    package static let maxColumn: Double = 820
    package static let gap: Double = 16
    package static let maxColumns = 3

    /// Columns for a list `width` wide (the space inside the list's horizontal padding).
    package static func columns(width: Double) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let n = Int(((width + gap) / (minColumn + gap)).rounded(.down))
        return min(maxColumns, max(1, n))
    }

    /// Each column's width for `columns` columns in `width` (never wider than `maxColumn`).
    package static func columnWidth(width: Double, columns: Int) -> Double {
        let n = Double(max(1, columns))
        let fit = (max(0, width) - gap * (n - 1)) / n
        return max(0, min(maxColumn, fit))
    }

    /// The whole list's width (centred in `width`).
    package static func contentWidth(width: Double, columns: Int) -> Double {
        let n = Double(max(1, columns))
        return columnWidth(width: width, columns: columns) * n + gap * (n - 1)
    }

    /// Card indices per column: each card (in order) goes to the column whose estimated height is
    /// the smallest so far (the leftmost on ties) — so every column stays newest-first, and the
    /// columns end within about one card of each other.
    package static func distribute(heights: [Double], columns: Int) -> [[Int]] {
        let n = max(1, columns)
        var out = Array(repeating: [Int](), count: n)
        var totals = Array(repeating: 0.0, count: n)
        for (i, h) in heights.enumerated() {
            var best = 0
            for c in 1..<max(1, n) where totals[c] < totals[best] { best = c }
            out[best].append(i)
            totals[best] += max(0, h) + gap
        }
        return out
    }

    /// A card's estimated height (points) from what it shows: the header, subject and summary,
    /// the paper rows shown, the 「其余 N 篇」 line and the footer.
    package static func estimatedHeight(rows: Int, hasMoreLine: Bool, hasConsent: Bool) -> Double {
        var h = 132.0                                   // header, subject, summary, footer, padding
        h += Double(max(0, rows)) * 58                  // a paper row
        if rows == 0 { h += 20 }                         // 「没有找到论文」
        if hasMoreLine { h += 26 }
        if hasConsent { h += 30 }
        return h
    }
}
