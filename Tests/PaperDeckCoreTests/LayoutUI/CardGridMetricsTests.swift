import Foundation
import Testing
@testable import PaperDeckCore

/// The library grid's width-driven layout (`CardGridMetrics`): columns follow the width, equal
/// columns fill the row exactly, one compact column below 620 pt, thumbnails scale with the card.
@Suite struct CardGridMetricsTests {
    typealias M = CardGridMetrics

    /// The window widths the renders check, as content widths (sidebar 236, inspector 380).
    static let contentWidths: [Double] = {
        var out: [Double] = []
        for window in [720.0, 900, 1100, 1280, 1440, 1680, 2000, 2560] {
            out.append(window >= 900 ? window - 236 : window)          // inspector closed
            if window >= 1100 { out.append(window - 236 - 380) }       // inspector open
        }
        return out + [300, 619.5, 620, 875, 876, 2324]
    }()

    @Test func everyRowIsFilledExactlyWithEqualColumns() {
        for width in Self.contentWidths where width >= M.compactBelow {
            let m = M(width: width)
            let available = width - 2 * M.margin
            #expect(m.style == .tiles)
            #expect(m.rowWidth <= available + 0.001, "\(width): \(m.rowWidth) > \(available)")
            // No ragged gap: what's left at the end of a row is only the half-point rounding.
            #expect(available - m.rowWidth < Double(m.columns) * 0.5 + 0.001, "\(width): gap \(available - m.rowWidth)")
            #expect(m.cardWidth >= M.minCardWidth, "\(width): \(m.cardWidth)")
            // One more column would make the cards narrower than the minimum.
            let more = (available - Double(m.columns) * M.gutter) / Double(m.columns + 1)
            #expect(more < M.minCardWidth, "\(width): \(m.columns + 1) columns of \(more) would fit")
        }
    }

    @Test func fromThreeColumnsOnCardsStayUnderTheMaximum() {
        var width = M.compactBelow
        while width <= 3000 {
            let m = M(width: width)
            if m.columns >= 3 { #expect(m.cardWidth <= M.maxCardWidth, "\(width): \(m.cardWidth)") }
            #expect(m.cardWidth < 430, "\(width): \(m.cardWidth)")              // two columns: ≈ 428 at most
            width += 7
        }
    }

    @Test func columnsGrowWithTheWidthAndNeverShrink() {
        var previous = 0
        var width = 300.0
        while width <= 3000 {
            let m = M(width: width)
            #expect(m.columns >= previous, "\(width)")
            previous = m.columns
            width += 3
        }
        #expect(M(width: 1044).columns == 3)            // 1280 window, inspector closed
        #expect(M(width: 664).columns == 2)             // 1280 window, inspector open
        #expect(M(width: 2324).columns == 7)            // 2560 window, inspector closed
        #expect(M(width: 1000).columns == 3)            // the gesture probe's 1000 pt grid
    }

    @Test func narrowColumnsGetOneCompactColumn() {
        for width in [0.0, 284, 484, 619.5] {
            let m = M(width: width)
            #expect(m.style == .compact && m.columns == 1, "\(width)")
            #expect(m.cardWidth == max(0, width - 2 * M.margin))
        }
        #expect(M(width: 620).style == .tiles && M(width: 620).columns == 2)
        #expect(M(width: .nan).style == .compact && M(width: .nan).cardWidth == 0)
        #expect(M(width: -50).cardWidth == 0 && M(width: .infinity).columns == 1)
    }

    @Test func theCompactThumbnailNeedsRoom() {
        #expect(!M(width: 284).showsCompactThumbnail)                         // 900 window, inspector open
        #expect(M(width: 484).showsCompactThumbnail)                          // 1100 window, inspector open
        #expect(!M(width: 1044).showsCompactThumbnail)                        // tiles never show the strip
        #expect(M(width: M.compactThumbnailMinCardWidth + 2 * M.margin).showsCompactThumbnail)
        #expect(!M(width: M.compactThumbnailMinCardWidth + 2 * M.margin - 1).showsCompactThumbnail)
    }

    @Test func thumbnailsScaleWithTheCardWithinBounds() {
        #expect(M.thumbnailHeight(cardWidth: 280) == 120)                     // today's card
        #expect(M.thumbnailHeight(cardWidth: 315) == 135)
        #expect(M.thumbnailHeight(cardWidth: 350) == 150)
        #expect(M.thumbnailHeight(cardWidth: 428) == 150)                     // capped
        #expect(M.thumbnailHeight(cardWidth: 200) == 112)                     // floor
        var last = 0.0
        for w in stride(from: 280.0, through: 430, by: 2) {
            let h = M.thumbnailHeight(cardWidth: w)
            #expect(h >= last && M.thumbnailHeights.contains(h))
            last = h
        }
    }

    @Test func rowsSliceEachSectionInOrder() {
        #expect(M.rows([1, 2, 3, 4, 5], columns: 2) == [[1, 2], [3, 4], [5]])
        #expect(M.rows([1, 2, 3], columns: 3) == [[1, 2, 3]])
        #expect(M.rows([1, 2], columns: 0) == [[1], [2]])
        #expect(M.rows([Int](), columns: 4).isEmpty)
        // Slicing matches the arrow keys: ↓ from a card lands on the card `columns` further on.
        let ids = (0..<7).map { "p\($0)" }
        for cols in 1...4 {
            let rows = M.rows(ids, columns: cols)
            for (r, row) in rows.enumerated() {
                for (c, id) in row.enumerated() {
                    let below = GridNav.move(from: id, .down, columns: cols, sections: [ids])
                    if r + 1 < rows.count {
                        #expect(below == rows[r + 1][min(c, rows[r + 1].count - 1)], "\(cols) \(id)")
                    }
                }
            }
        }
    }
}
