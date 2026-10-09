import CoreGraphics
import Foundation

// What a click on the frozen still really points at, from the pixels alone (F3, CUX-8; fix-capture-ux).
// The overlay crops a band around a click so local OCR can find the paragraph under it; only that
// paragraph — or, when there is none, the figure around the click, or a small band — is ever sent.
// ⌥-click sends the figure's own bounds. A flat crop (a protected window, a sleeping display, a blank
// margin) is refused before anything is sent. Pure: synthetic images in the tests, never a screen.

/// A coarse map of where a capture has "ink" (anything that differs from its background).
package struct InkMap: Sendable {
    package let columns: Int
    package let rows: Int
    /// Source-image pixels per cell, along x and y.
    package let cellWidth: CGFloat
    package let cellHeight: CGFloat
    /// Row-major, `columns × rows`.
    package let ink: [Bool]
    /// The background luminance (0…1): the most common one.
    package let background: Double

    /// A cell differs from the background when one of its pixels is this far from it (0…1).
    package static let threshold = 0.12
    /// The working copy is at most this many pixels on its long side, and at most one pixel per point.
    package static let maxWorkSide = 1_400

    /// The map of `image` with cells of about `cellPoints` points (`scale`: the image's pixels per
    /// point); `maxSide` caps the working copy's long side.
    package init?(_ image: CGImage, scale: CGFloat, cellPoints: CGFloat = CaptureFigure.cellPoints, maxSide: Int = maxWorkSide) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, scale > 0 else { return nil }
        let f = min(1, 1 / scale, CGFloat(maxSide) / CGFloat(max(w, h)))
        let ww = max(1, Int((CGFloat(w) * f).rounded())), wh = max(1, Int((CGFloat(h) * f).rounded()))
        guard let ctx = CGContext(data: nil, width: ww, height: wh, bitsPerComponent: 8, bytesPerRow: ww,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: ww, height: wh))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: ww, height: wh))
        let px = UnsafeBufferPointer(start: raw.bindMemory(to: UInt8.self, capacity: ww * wh), count: ww * wh)
        // The background: the most common luminance (256 levels, the mode's ±2 neighbours averaged).
        var hist = [Int](repeating: 0, count: 256)
        for v in px { hist[Int(v)] += 1 }
        let mode = hist.indices.max { hist[$0] < hist[$1] } ?? 255
        var sum = 0, n = 0
        for v in max(0, mode - 2)...min(255, mode + 2) { sum += v * hist[v]; n += hist[v] }
        let bg = n > 0 ? Double(sum) / Double(n) / 255 : 1
        // Cells of about `cellPoints` points of the working copy (row 0 of a bitmap context's data
        // is the drawn image's top row, the space of the source's pixels).
        let cell = max(1, Int((cellPoints * scale * f).rounded()))
        let cols = (ww + cell - 1) / cell, rws = (wh + cell - 1) / cell
        var ink = [Bool](repeating: false, count: cols * rws)
        let t = Int((Self.threshold * 255).rounded())
        let b = Int((bg * 255).rounded())
        // A lookup of which levels count as ink keeps the per-pixel loop to one load and one branch.
        var isInk = [Bool](repeating: false, count: 256)
        for v in 0..<256 { isInk[v] = abs(v - b) > t }
        for y in 0..<wh {
            let rowBase = (y / cell) * cols
            let base = y * ww
            for x in 0..<ww where isInk[Int(px[base + x])] {
                ink[rowBase + x / cell] = true
            }
        }
        self.columns = cols
        self.rows = rws
        self.cellWidth = CGFloat(cell) / f
        self.cellHeight = CGFloat(cell) / f
        self.ink = ink
        self.background = bg
    }

    /// No cell differs from the background: one flat colour.
    package var isBlank: Bool { !ink.contains(true) }

    /// Some cell overlapping `rect` (source pixels) has ink.
    package func hasInk(in rect: CGRect) -> Bool {
        let r = rect.standardized
        guard r.width > 0, r.height > 0 else { return false }
        let c0 = max(0, Int(r.minX / cellWidth)), c1 = min(columns - 1, Int((r.maxX - 0.001) / cellWidth))
        let r0 = max(0, Int(r.minY / cellHeight)), r1 = min(rows - 1, Int((r.maxY - 0.001) / cellHeight))
        guard c0 <= c1, r0 <= r1 else { return false }
        for row in r0...r1 { for c in c0...c1 where ink[row * columns + c] { return true } }
        return false
    }

    package func isInk(_ c: Int, _ r: Int) -> Bool { c >= 0 && r >= 0 && c < columns && r < rows && ink[r * columns + c] }

    /// The cell holding a source pixel.
    package func cell(at p: CGPoint) -> (Int, Int) {
        (min(max(Int(p.x / cellWidth), 0), columns - 1), min(max(Int(p.y / cellHeight), 0), rows - 1))
    }

    /// The ink cells connected to the cell at `p` once ink within `join` cells of each other counts as
    /// touching; the seed may be up to `reach` cells away. Their bounds in source pixels, nil when no
    /// ink is within reach.
    package func component(around p: CGPoint, join: Int, reach: Int) -> CGRect? {
        let grown = dilated(by: max(0, join))
        let (sc, sr) = cell(at: p)
        guard let seed = nearest(in: grown, to: (sc, sr), within: max(0, reach)) else { return nil }
        var seen = [Bool](repeating: false, count: columns * rows)
        var stack = [seed.1 * columns + seed.0]
        seen[stack[0]] = true
        var minC = Int.max, minR = Int.max, maxC = -1, maxR = -1
        while let i = stack.popLast() {
            let c = i % columns, r = i / columns
            if ink[i] {
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
            }
            for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nc = c + dc, nr = r + dr
                guard nc >= 0, nr >= 0, nc < columns, nr < rows else { continue }
                let j = nr * columns + nc
                if grown[j], !seen[j] { seen[j] = true; stack.append(j) }
            }
        }
        guard maxC >= 0 else { return nil }
        return CGRect(x: CGFloat(minC) * cellWidth, y: CGFloat(minR) * cellHeight,
                      width: CGFloat(maxC - minC + 1) * cellWidth, height: CGFloat(maxR - minR + 1) * cellHeight)
    }

    /// The ink grown by `r` cells each way (a square: separable max filters).
    private func dilated(by r: Int) -> [Bool] {
        guard r > 0 else { return ink }
        var horizontal = [Bool](repeating: false, count: ink.count)
        for row in 0..<rows {
            // Two passes keep it linear: distance to the nearest ink on the left, then the right.
            var left = -Int.max / 2
            for c in 0..<columns {
                if ink[row * columns + c] { left = c }
                if c - left <= r { horizontal[row * columns + c] = true }
            }
            var right = Int.max / 2
            for c in stride(from: columns - 1, through: 0, by: -1) {
                if ink[row * columns + c] { right = c }
                if right - c <= r { horizontal[row * columns + c] = true }
            }
        }
        var out = [Bool](repeating: false, count: ink.count)
        for c in 0..<columns {
            var up = -Int.max / 2
            for row in 0..<rows {
                if horizontal[row * columns + c] { up = row }
                if row - up <= r { out[row * columns + c] = true }
            }
            var down = Int.max / 2
            for row in stride(from: rows - 1, through: 0, by: -1) {
                if horizontal[row * columns + c] { down = row }
                if down - row <= r { out[row * columns + c] = true }
            }
        }
        return out
    }

    /// The nearest set cell of `mask` to `seed` within `reach` cells (Chebyshev rings, the closest
    /// by distance inside the first ring that has one).
    private func nearest(in mask: [Bool], to seed: (Int, Int), within reach: Int) -> (Int, Int)? {
        if mask[seed.1 * columns + seed.0] { return seed }
        for d in stride(from: 1, through: reach, by: 1) {
            var best: (Int, Int)?
            var bestDistance = Int.max
            for r in (seed.1 - d)...(seed.1 + d) {
                for c in (seed.0 - d)...(seed.0 + d) where max(abs(c - seed.0), abs(r - seed.1)) == d {
                    guard c >= 0, r >= 0, c < columns, r < rows, mask[r * columns + c] else { continue }
                    let dist = (c - seed.0) * (c - seed.0) + (r - seed.1) * (r - seed.1)
                    if dist < bestDistance { bestDistance = dist; best = (c, r) }
                }
            }
            if let best { return best }
        }
        return nil
    }
}

package enum CaptureFigure {
    /// The ink map's cell, in points.
    package static let cellPoints: CGFloat = 2
    /// Ink closer than this (points) belongs to one figure (bars and their axis, a chart's labels).
    package static let joinGap: CGFloat = 8
    /// A click this close (points) to a figure still picks it.
    package static let reach: CGFloat = 16
    /// Room kept around a figure's ink (points).
    package static let padding: CGFloat = 6
    /// A figure crop is at least this big (points) — a lone mark keeps a little context.
    package static let minSide: CGFloat = 48
    /// What a click sends when nothing is found under it (points): never the whole OCR band.
    package static let smallBand = CGSize(width: 320, height: 200)

    /// Nothing legible: one flat colour (a protected window comes back black, a blank margin white).
    package static func isBlank(_ image: CGImage) -> Bool {
        guard let map = InkMap(image, scale: 1, cellPoints: 4, maxSide: 640) else { return true }
        return map.isBlank
    }

    /// The figure around `point` (pixels of `image`, `scale` pixels per point): the ink connected to
    /// it, padded, at least `minSide`, inside the image; nil when no ink is within `reach`.
    package static func bounds(in image: CGImage, around point: CGPoint, scale: CGFloat) -> CGRect? {
        guard scale > 0, let map = InkMap(image, scale: scale) else { return nil }
        return bounds(in: map, imageSize: CGSize(width: image.width, height: image.height), around: point, scale: scale)
    }

    /// The same on an image's ink map (`imageSize` its pixels).
    package static func bounds(in map: InkMap, imageSize: CGSize, around point: CGPoint, scale: CGFloat) -> CGRect? {
        guard scale > 0 else { return nil }
        let cellPoints = map.cellWidth / scale
        let join = max(1, Int((joinGap / 2 / cellPoints).rounded(.up)))
        let reachCells = max(1, Int((reach / cellPoints).rounded(.up)))
        guard let ink = map.component(around: point, join: join, reach: reachCells) else { return nil }
        let pad = padding * scale
        var r = ink.insetBy(dx: -pad, dy: -pad)
        let min = minSide * scale
        if r.width < min { r = r.insetBy(dx: -(min - r.width) / 2, dy: 0) }
        if r.height < min { r = r.insetBy(dx: 0, dy: -(min - r.height) / 2) }
        let bounds = CGRect(origin: .zero, size: imageSize)
        let clipped = CaptureGeometry.snap(r, within: bounds)
        return clipped.width >= 1 && clipped.height >= 1 ? clipped : nil
    }
}

/// What a click on the still sends (F3): planned from the band's pixels before anything leaves the overlay.
package enum CaptureClickPlan {
    package enum Plan: Sendable, Equatable {
        /// Read `band` (display-local points) on this Mac and keep the paragraph under the click — the
        /// focus' fallback (the figure / small band) when there is none.
        case paragraph(band: CGRect, focus: ExplainFocus)
        /// ⌥: the figure around the click (display-local points), or the small band.
        case figure(CGRect)
        /// Nothing legible under or near the click: say so, send nothing.
        case blank
    }

    /// The area searched for the figure around a click (points): larger than the OCR band, so a
    /// figure wider than the band is found whole (only its own bounds are ever sent).
    package static let figureSearch = CGSize(width: 1400, height: 900)
    /// A plain click's OCR band grows to hold the figure under it up to this size (points).
    package static let maxGrownBand = CGSize(width: 1000, height: 640)

    /// The plan for a click at `local` on a display of `displaySize` (points); `window`: the bounds of
    /// the window under the click (display-local points) — nothing is read outside it; `crop` gives the
    /// still's pixels of a display-local rect. nil: the still couldn't be read.
    package static func plan(click local: CGPoint, displaySize: CGSize, window: CGRect?, term: Bool, figure: Bool,
                             crop: (CGRect) -> CGImage?) -> Plan? {
        let band0 = CaptureGeometry.clip(CaptureGeometry.band(around: local, displaySize: displaySize), toWindow: window,
                                         keeping: local)
        let search = CaptureGeometry.clip(CaptureGeometry.band(around: local, displaySize: displaySize, size: figureSearch)
                                            .union(band0), toWindow: window, keeping: local)
        guard band0.width >= 1, band0.height >= 1, let image = crop(search), image.width > 0 else { return nil }
        let scale = CGFloat(image.width) / search.width
        // One ink map of the search area answers it all: anything in the band, the figure, the small band.
        guard let map = InkMap(image, scale: scale) else { return nil }
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - search.minX) * scale, y: (r.minY - search.minY) * scale, width: r.width * scale, height: r.height * scale)
        }
        if !map.hasInk(in: px(band0)) { return .blank }
        let size = CGSize(width: image.width, height: image.height)
        let clickPx = CGPoint(x: (local.x - search.minX) * scale, y: (local.y - search.minY) * scale)
        let figureRect = CaptureFigure.bounds(in: map, imageSize: size, around: clickPx, scale: scale).map {
            CGRect(x: search.minX + $0.minX / scale, y: search.minY + $0.minY / scale, width: $0.width / scale, height: $0.height / scale)
        }
        let fallback: CGRect
        if let figureRect {
            fallback = figureRect
        } else {
            let inBand = CGPoint(x: local.x - band0.minX, y: local.y - band0.minY)
            let small = CaptureGeometry.band(around: inBand, displaySize: band0.size, size: CaptureFigure.smallBand)
                .offsetBy(dx: band0.minX, dy: band0.minY)
            // Nothing near the click and the small band is empty too: nothing to explain here.
            if !map.hasInk(in: px(small)) { return .blank }
            fallback = small
        }
        if figure { return .figure(fallback) }
        // The band read on this Mac holds the whole figure when it is not too large (else the figure is
        // cut at the band, never widened past it).
        let band = fit(band0.union(fallback), keeping: fallback, max: maxGrownBand) ?? band0
        guard let focus = ExplainFocus(local: local, in: band, term: term, fallback: fallback.intersection(band)) else { return nil }
        return .paragraph(band: band, focus: focus)
    }

    /// `outer` cut down to at most `max` on each axis around `inner` (kept whole, centred where there
    /// is room); nil when `inner` itself is larger than `max`.
    package static func fit(_ outer: CGRect, keeping inner: CGRect, max m: CGSize) -> CGRect? {
        guard inner.width <= m.width, inner.height <= m.height else { return nil }
        func axis(_ oMin: CGFloat, _ oMax: CGFloat, _ iMin: CGFloat, _ iMax: CGFloat, _ limit: CGFloat) -> (CGFloat, CGFloat) {
            guard oMax - oMin > limit else { return (oMin, oMax) }
            let extra = (limit - (iMax - iMin)) / 2
            var lo = iMin - extra, hi = iMax + extra
            if lo < oMin { hi += oMin - lo; lo = oMin }
            if hi > oMax { lo -= hi - oMax; hi = oMax }
            return (Swift.max(lo, oMin), Swift.min(hi, oMax))
        }
        let (x0, x1) = axis(outer.minX, outer.maxX, inner.minX, inner.maxX, m.width)
        let (y0, y1) = axis(outer.minY, outer.maxY, inner.minY, inner.maxY, m.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
