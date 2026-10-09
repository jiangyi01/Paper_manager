import CoreGraphics
import Foundation
@testable import PaperDeckCore

/// Fixtures of the capture polish (CUX-7 / CUX-8): a page model read by a fake OCR that, like Vision
/// on a crop, only sees the part it is given and answers in that part's pixels; synthetic stills drawn
/// in memory — never a screen, never a permission.
enum PolishKit {
    /// One text line of a page (image pixels) and the paragraph it belongs to.
    struct Line: Sendable {
        var text: String
        var box: CGRect
        var paragraph: Int
    }

    /// A paragraph of `count` lines `height` px tall with `gap` px between them, from `origin`, `width`
    /// px wide. Each line has enough characters to count as text.
    static func paragraph(_ id: Int, origin: CGPoint, width: CGFloat, count: Int, height: CGFloat = 24, gap: CGFloat = 10) -> [Line] {
        (0..<count).map { i in
            Line(text: "p\(id) line \(i) alpha beta gamma delta",
                 box: CGRect(x: origin.x, y: origin.y + CGFloat(i) * (height + gap), width: width, height: height), paragraph: id)
        }
    }

    /// Reads `page` like Vision reads a crop: only the lines at least half inside `rect`, clipped to it,
    /// in `rect`'s own pixels; records every rect asked for. `failing`: the call indices that fail.
    final class FakeOCR: @unchecked Sendable {
        private let lock = NSLock()
        let page: [Line]
        let failing: Set<Int>
        private var asked: [CGRect] = []

        init(_ page: [Line], failing: Set<Int> = []) { self.page = page; self.failing = failing }

        var calls: [CGRect] { lock.withLock { asked } }

        func read(_ rect: CGRect) -> OCRResult? {
            let index: Int = lock.withLock { asked.append(rect); return asked.count - 1 }
            if failing.contains(index) { return nil }
            var lines: [OCRLine] = []
            var paragraphs: [OCRParagraph] = []
            for id in Array(Set(page.map(\.paragraph))).sorted() {
                var indices: [Int] = []
                var texts: [String] = []
                for l in page where l.paragraph == id {
                    let visible = l.box.intersection(rect)
                    guard !visible.isNull, visible.height >= 0.5 * l.box.height, visible.width >= 1 else { continue }
                    indices.append(lines.count)
                    texts.append(l.text)
                    lines.append(OCRLine(text: l.text, box: visible.offsetBy(dx: -rect.minX, dy: -rect.minY), confidence: 0.9))
                }
                guard !indices.isEmpty else { continue }
                let box = indices.map { lines[$0].box }.reduce(CGRect.null) { $0.union($1) }
                paragraphs.append(OCRParagraph(text: texts.joined(separator: " "), box: box, lineIndices: indices))
            }
            return OCRResult(lines: lines, paragraphs: paragraphs, text: paragraphs.map(\.text).joined(separator: "\n\n"),
                             meanConfidence: lines.isEmpty ? 0 : 0.9)
        }
    }

    /// A still of `size` points at `scale`, drawn by `draw` in points (top-left origin).
    static func still(_ size: CGSize, scale: CGFloat = 2, fill: CGFloat = 1, _ draw: (CGContext) -> Void = { _ in }) -> CGImage? {
        UXKit.display(size, scale: scale, fill: fill, draw)
    }

    static func screens(_ image: CGImage, size: CGSize, origin: CGPoint = .zero, scale: CGFloat = 2, id: CGDirectDisplayID = 1) -> FrozenScreens {
        FrozenScreens(displays: [FrozenDisplay(id: id, frame: CGRect(origin: origin, size: size), scale: scale, image: image)])
    }

    /// A 5K display (2560 × 1440 pt at 2×, 5120 × 2880 px) full of text-like words in two columns and a
    /// chart: what a full-screen capture of a paper looks like to the encoder.
    static let fiveK = CGSize(width: 2560, height: 1440)

    static func fiveKPage() -> CGImage? {
        still(fiveK) { ctx in
            ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            var seed: UInt64 = 11
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 40) / CGFloat(1 << 24)
            }
            for column in [CGRect(x: 120, y: 80, width: 1100, height: 1280), CGRect(x: 1340, y: 80, width: 1100, height: 560)] {
                var y = column.minY
                while y + 14 <= column.maxY {
                    var x = column.minX
                    while x < column.maxX - 20 {
                        let w = 18 + 60 * next()
                        ctx.fill(CGRect(x: x, y: y + 3 * next(), width: min(w, column.maxX - x), height: 10))
                        x += w + 6
                    }
                    y += 20
                }
            }
            UXKit.chart(ctx, CGRect(x: 1400, y: 760, width: 960, height: 560))
        }
    }
}
