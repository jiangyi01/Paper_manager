import CoreGraphics
import Foundation

/// Where the explanation panel goes (LN §7.1, dive-ui §4.1): to the right of the selection if there
/// is room, else left, else below, else above — clamped to the screen's visible frame and never
/// covering the selection when any side has room; a selection as large as the screen gets the panel
/// inside its top-right corner. Text triggers anchor at the mouse (`pointAnchor`, or
/// `frame(near:size:visibleFrame:)` below-right of the cursor).
///
/// AppKit coordinates (Cocoa global: bottom-left origin, y up), the space of `NSWindow.frame` and
/// `NSScreen.visibleFrame`: "below" is a smaller y; displays left of / below the main one have
/// negative origins. Pure; the App passes the screens. One type for both Explain lanes: the UI
/// lane's API (`frame(size:anchor:visibleFrame:gap:)`, `pointAnchor`, `screenIndex`, `height`,
/// `cascade`, the size constants) and the capture lane's (`frame(for:…)`, `placement`,
/// `frame(near:…)`, `visibleFrame(for:screens:)`) share one rule.
package enum PanelPlacement {
    /// Points between the selection (or the mouse) and the panel.
    package static let gap: CGFloat = 12
    /// The mouse anchor's offset (below-right of the cursor, clear of the pointer).
    package static let mouseOffset = CGSize(width: 16, height: 16)
    /// Default width and the height range (the body scrolls beyond the maximum).
    package static let width: CGFloat = 420
    package static let minHeight: CGFloat = 220
    package static let maxHeight: CGFloat = 560
    /// Pinned panels step this far down-right from the previous one.
    package static let cascadeStep: CGFloat = 24

    /// `inside`: no side had room (the selection fills the screen): the panel sits in its top-right corner.
    package enum Side: String, Sendable, Equatable, CaseIterable { case right, left, below, above, inside }

    /// The panel's frame for `size` next to `anchor` (Cocoa; a zero-size anchor is the mouse), `size`
    /// shrunk to fit `visibleFrame`, and the side it went to.
    package static func frame(size: CGSize, anchor: CGRect, visibleFrame: CGRect, gap: CGFloat = gap) -> (frame: CGRect, side: Side) {
        let vf = visibleFrame.standardized
        let a = anchor.standardized
        let w = min(size.width, vf.width), h = min(size.height, vf.height)
        // Beside the anchor: the panel's top at the anchor's top, clamped vertically.
        let besideY = clamp(a.maxY - h, vf.minY, vf.maxY - h)
        if a.maxX + gap + w <= vf.maxX {
            return (CGRect(x: max(a.maxX + gap, vf.minX), y: besideY, width: w, height: h), .right)
        }
        if a.minX - gap - w >= vf.minX {
            return (CGRect(x: min(a.minX - gap - w, vf.maxX - w), y: besideY, width: w, height: h), .left)
        }
        // Under / over it: left edges aligned, clamped horizontally.
        let x = clamp(a.minX, vf.minX, vf.maxX - w)
        if a.minY - gap - h >= vf.minY {
            return (CGRect(x: x, y: a.minY - gap - h, width: w, height: h), .below)
        }
        if a.maxY + gap + h <= vf.maxY {
            return (CGRect(x: x, y: a.maxY + gap, width: w, height: h), .above)
        }
        return (CGRect(x: clamp(a.maxX - w - gap, vf.minX, vf.maxX - w), y: clamp(a.maxY - h - gap, vf.minY, vf.maxY - h),
                       width: w, height: h), .inside)
    }

    /// The panel's frame for a selection (the same rule).
    package static func frame(for selection: CGRect, size: CGSize, visibleFrame: CGRect, gap: CGFloat = gap) -> CGRect {
        frame(size: size, anchor: selection, visibleFrame: visibleFrame, gap: gap).frame
    }

    /// The frame and the side (nil: `inside`, no side had room).
    package static func placement(for selection: CGRect, size: CGSize, visibleFrame: CGRect,
                                  gap: CGFloat = gap) -> (frame: CGRect, side: Side?) {
        let p = frame(size: size, anchor: selection, visibleFrame: visibleFrame, gap: gap)
        return (p.frame, p.side == .inside ? nil : p.side)
    }

    /// A zero-size anchor at the mouse.
    package static func pointAnchor(_ p: CGPoint) -> CGRect { CGRect(origin: p, size: .zero) }

    /// The panel's frame near the mouse (Services, the clipboard): below-right of the cursor,
    /// flipped left / up at the screen's edges, clamped to `visibleFrame`.
    package static func frame(near point: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let vis = visibleFrame.standardized
        let w = min(size.width, vis.width), h = min(size.height, vis.height)
        var x = point.x + mouseOffset.width
        if x + w > vis.maxX { x = point.x - mouseOffset.width - w }
        var y = point.y - mouseOffset.height - h
        if y < vis.minY { y = point.y + mouseOffset.height }
        return CGRect(x: clamp(x, vis.minX, vis.maxX - w), y: clamp(y, vis.minY, vis.maxY - h), width: w, height: h)
    }

    /// The screen (index into `frames`) that holds `point`; else the nearest one; nil without screens.
    package static func screenIndex(for point: CGPoint, frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: { $0.contains(point) }) { return i }
        return frames.indices.min { distance(point, frames[$0]) < distance(point, frames[$1]) }
    }

    /// The visible frame of the screen showing most of `rect` (the nearest screen when none
    /// intersects it); nil without screens. `screens` are (frame, visibleFrame) pairs, Cocoa.
    package static func visibleFrame(for rect: CGRect, screens: [(frame: CGRect, visible: CGRect)]) -> CGRect? {
        guard !screens.isEmpty else { return nil }
        let r = rect.standardized
        if let best = screens.max(by: { overlap($0.frame, r) < overlap($1.frame, r) }), overlap(best.frame, r) > 0 {
            return best.visible
        }
        let c = CGPoint(x: r.midX, y: r.midY)
        return screens.min { distance(c, $0.frame) < distance(c, $1.frame) }?.visible
    }

    /// The panel's height for content of `contentHeight`: within the range and at most 60 % of the screen.
    package static func height(for contentHeight: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let cap = max(minHeight, min(maxHeight, visibleFrame.height * 0.6))
        return clamp(contentHeight, minHeight, cap)
    }

    /// The panel's frame once its content asks for `height` (CUX-5: the answer streams in and the panel
    /// grows), keeping the side it opened on and never growing over the selection:
    /// - beside it (right / left): the top stays, the panel moves up only at the screen's bottom;
    /// - below it: the top stays under the selection; with too little room below, the height is capped
    ///   there (the body scrolls) — or, below `minHeight`, the placement runs again;
    /// - above it: the bottom stays over the selection and the panel grows upward, capped at the top;
    /// - inside (the selection fills the screen): the top stays, clamped.
    /// `current` is the panel's frame now (Cocoa), `anchor` the selection, `visibleFrame` its screen's.
    package static func refit(_ current: CGRect, side: Side, anchor: CGRect, height: CGFloat, visibleFrame: CGRect,
                              gap: CGFloat = gap) -> (frame: CGRect, side: Side) {
        let vf = visibleFrame.standardized
        let f = current.standardized
        let h = min(max(height, 1), vf.height)
        switch side {
        case .right, .left, .inside:
            return (CGRect(x: f.minX, y: clamp(f.maxY - h, vf.minY, vf.maxY - h), width: f.width, height: h), side)
        case .below:
            let top = min(f.maxY, vf.maxY)
            let room = top - vf.minY
            if h <= room { return (CGRect(x: f.minX, y: top - h, width: f.width, height: h), .below) }
            if room >= minHeight { return (CGRect(x: f.minX, y: vf.minY, width: f.width, height: room), .below) }
            return frame(size: CGSize(width: f.width, height: h), anchor: anchor, visibleFrame: vf, gap: gap)
        case .above:
            let bottom = max(f.minY, vf.minY)
            let room = vf.maxY - bottom
            if h <= room { return (CGRect(x: f.minX, y: bottom, width: f.width, height: h), .above) }
            if room >= minHeight { return (CGRect(x: f.minX, y: bottom, width: f.width, height: room), .above) }
            return frame(size: CGSize(width: f.width, height: h), anchor: anchor, visibleFrame: vf, gap: gap)
        }
    }

    /// The `index`-th pinned panel's frame, stepped from `base` and kept on screen.
    package static func cascade(_ base: CGRect, index: Int, visibleFrame vf: CGRect) -> CGRect {
        guard index > 0 else { return base }
        let step = cascadeStep * CGFloat(index)
        return CGRect(x: clamp(base.minX + step, vf.minX, vf.maxX - base.width),
                      y: clamp(base.minY - step, vf.minY, vf.maxY - base.height), width: base.width, height: base.height)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        hi < lo ? lo : min(max(v, lo), hi)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
