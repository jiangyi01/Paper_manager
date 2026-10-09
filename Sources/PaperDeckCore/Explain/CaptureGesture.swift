import CoreGraphics
import Foundation

/// The frame and lens gestures over the frozen screen (dive-capture §2, LN §4.4), pure so the rules
/// are tested without a window: a drag is a box; a release within `CaptureGeometry.clickSide` of
/// where it started is a click on the paragraph under it (⇧: the term; ⌥: the band as a figure);
/// the scroll wheel zooms the lens between `zoomRange`'s ends. Coordinates are display-local points
/// (top-left origin, y down — the overlay view's own space). Phase-3 integration (Lead).
package enum CaptureGesture {
    /// What a mouse release means.
    package enum Outcome: Sendable, Equatable {
        /// A box (display-local points, clamped to the display); `figure`: ⌥ was held.
        case box(CGRect, figure: Bool)
        /// A click: explain what is under `point` — its paragraph, or `term` the word.
        case point(CGPoint, term: Bool, figure: Bool)
    }

    /// The release from `start` to `end` on a display of `size`. A box needs both sides at least
    /// `clickSide`; anything smaller is a click at the release point (a tiny wobble while clicking
    /// is not a box). Both modes take a drawn box; the lens is for clicking.
    package static func release(from start: CGPoint, to end: CGPoint, option: Bool, shift: Bool,
                                displaySize size: CGSize) -> Outcome {
        let bounds = CGRect(origin: .zero, size: size)
        let rect = box(from: start, to: end, displaySize: size)
        if CaptureGeometry.isClick(rect) {
            let p = CGPoint(x: min(max(end.x, bounds.minX), bounds.maxX), y: min(max(end.y, bounds.minY), bounds.maxY))
            return .point(p, term: shift && !option, figure: option)
        }
        return .box(rect, figure: option)
    }

    /// The box a drag from `start` to `end` draws, clamped to the display (a drag never leaves the
    /// display it started on).
    package static func box(from start: CGPoint, to end: CGPoint, displaySize size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .intersection(bounds)
        return r.isNull ? CGRect(origin: start, size: .zero) : r
    }

    // MARK: Lens

    /// The lens' diameter on screen, in points.
    package static let lensDiameter: CGFloat = 168
    package static let zoomRange: ClosedRange<CGFloat> = 1.5...6
    package static let defaultZoom: CGFloat = 2
    /// One scroll-wheel notch multiplies the zoom by this much.
    package static let zoomStep: CGFloat = 1.12

    /// The zoom after a scroll of `dy` (positive: away from the user, zooms in), kept in `zoomRange`.
    package static func zoom(_ current: CGFloat, scrolledBy dy: CGFloat) -> CGFloat {
        guard dy != 0, dy.isFinite else { return clampZoom(current) }
        let notches = max(-4, min(4, dy))
        return clampZoom(current * pow(zoomStep, notches))
    }

    package static func clampZoom(_ z: CGFloat) -> CGFloat {
        guard z.isFinite else { return defaultZoom }
        return min(max(z, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The part of the display the lens magnifies (display-local points): a square of
    /// `diameter / zoom` centred on the cursor.
    package static func lensSource(at cursor: CGPoint, zoom: CGFloat, diameter: CGFloat = lensDiameter) -> CGRect {
        let side = diameter / clampZoom(zoom)
        return CGRect(x: cursor.x - side / 2, y: cursor.y - side / 2, width: side, height: side)
    }

    /// The offset that puts the display's point `cursor`, magnified `zoom` times, at the centre of a
    /// lens of `diameter` (the still is drawn `zoom` times larger and shifted by this).
    package static func lensOffset(at cursor: CGPoint, zoom: CGFloat, diameter: CGFloat = lensDiameter) -> CGSize {
        let z = clampZoom(zoom)
        return CGSize(width: diameter / 2 - cursor.x * z, height: diameter / 2 - cursor.y * z)
    }

    // MARK: Labels

    /// The box's size label ("612 × 240", in points).
    package static func sizeLabel(_ rect: CGRect) -> String {
        let r = rect.standardized
        return "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
    }

    /// Where the size label sits: under the box's bottom-right corner, or inside it when the box
    /// reaches the display's bottom edge (label size `label`, display `size`).
    package static func labelOrigin(for rect: CGRect, label: CGSize, displaySize size: CGSize, gap: CGFloat = 6) -> CGPoint {
        let r = rect.standardized
        var x = r.maxX - label.width
        var y = r.maxY + gap
        if y + label.height > size.height { y = r.maxY - label.height - gap }
        x = min(max(x, 0), max(size.width - label.width, 0))
        y = min(max(y, 0), max(size.height - label.height, 0))
        return CGPoint(x: x, y: y)
    }
}
