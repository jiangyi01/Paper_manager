import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// The explanation panel's placement (LN §7.1): right, else left, else below, else above the
/// selection, clamped to the visible frame, never over the selection when a side has room; near
/// the mouse for text triggers; the screen showing most of the selection (Cocoa coordinates).
@Suite struct PanelPlacementTests {
    static let vis = CGRect(x: 0, y: 0, width: 1440, height: 875)
    static let size = CGSize(width: 420, height: 300)

    @Test func prefersTheRightThenLeftThenBelowThenAbove() {
        let middle = CGRect(x: 500, y: 400, width: 200, height: 100)
        let r = PanelPlacement.placement(for: middle, size: Self.size, visibleFrame: Self.vis)
        #expect(r.side == .right && r.frame == CGRect(x: 712, y: 200, width: 420, height: 300))   // top-aligned
        let nearRight = CGRect(x: 1100, y: 400, width: 200, height: 100)
        let l = PanelPlacement.placement(for: nearRight, size: Self.size, visibleFrame: Self.vis)
        #expect(l.side == .left && l.frame.maxX == 1100 - PanelPlacement.gap)
        let wide = CGRect(x: 100, y: 500, width: 1200, height: 100)
        let b = PanelPlacement.placement(for: wide, size: Self.size, visibleFrame: Self.vis)
        #expect(b.side == .below && b.frame == CGRect(x: 100, y: 500 - 12 - 300, width: 420, height: 300))
        let wideLow = CGRect(x: 100, y: 100, width: 1200, height: 100)
        let a = PanelPlacement.placement(for: wideLow, size: Self.size, visibleFrame: Self.vis)
        #expect(a.side == .above && a.frame.minY == 212)
        for f in [r.frame, l.frame, b.frame, a.frame] { #expect(Self.vis.contains(f)) }
        #expect(!r.frame.intersects(middle) && !l.frame.intersects(nearRight) && !b.frame.intersects(wide) && !a.frame.intersects(wideLow))
    }

    @Test func clampsVerticallyAndShrinksToTheScreen() {
        // Selection at the very top: the right-hand panel is pushed down onto the screen.
        let top = CGRect(x: 100, y: 800, width: 200, height: 70)
        let f = PanelPlacement.frame(for: top, size: Self.size, visibleFrame: Self.vis)
        #expect(f.maxY <= Self.vis.maxY && f.minX == 312)
        // A panel larger than the screen is shrunk to it.
        let big = PanelPlacement.frame(for: top, size: CGSize(width: 3000, height: 2000), visibleFrame: Self.vis)
        #expect(big.size == Self.vis.size && Self.vis.contains(big))
        // A visible frame that doesn't start at the origin (a second screen, the menu bar).
        let second = CGRect(x: -1920, y: -280, width: 1920, height: 1055)
        let g = PanelPlacement.frame(for: CGRect(x: -1900, y: 0, width: 100, height: 100), size: Self.size, visibleFrame: second)
        #expect(second.contains(g) && g.minX == -1900 + 100 + 12)
    }

    @Test func noSideHasRoomSoTheLeastCoveringClampWins() {
        // The selection fills almost the whole screen.
        let sel = CGRect(x: 20, y: 20, width: 1400, height: 835)
        let p = PanelPlacement.placement(for: sel, size: Self.size, visibleFrame: Self.vis)
        #expect(p.side == nil && Self.vis.contains(p.frame))
        let overlap = p.frame.intersection(sel)
        #expect(overlap.width * overlap.height <= 420 * 300)
    }

    @Test func nearTheMouseFlipsAtTheEdges() {
        let m = PanelPlacement.frame(near: CGPoint(x: 400, y: 600), size: Self.size, visibleFrame: Self.vis)
        #expect(m == CGRect(x: 416, y: 600 - 16 - 300, width: 420, height: 300))      // below-right of the cursor
        let corner = PanelPlacement.frame(near: CGPoint(x: 1400, y: 100), size: Self.size, visibleFrame: Self.vis)
        #expect(corner.maxX == 1400 - 16 && corner.minY == 116)                        // flipped left and up
        #expect(Self.vis.contains(corner))
    }

    /// The Explain UI lane's placement API (one `PanelPlacement` for both lanes): the same rule,
    /// `inside` when no side has room, the mouse anchor, screens, height and cascade.
    @Test func theUILanesAPIKeepsItsRule() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let mid = CGRect(x: 400, y: 400, width: 300, height: 100)
        let right = PanelPlacement.frame(size: Self.size, anchor: mid, visibleFrame: screen)
        #expect(right.side == .right && right.frame.minX >= mid.maxX && right.frame.maxY == mid.maxY)
        let huge = screen.insetBy(dx: 10, dy: 10)
        let inside = PanelPlacement.frame(size: Self.size, anchor: huge, visibleFrame: screen)
        #expect(inside.side == .inside && screen.contains(inside.frame))
        #expect(PanelPlacement.placement(for: huge, size: Self.size, visibleFrame: screen).side == nil)
        let leftScreen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let atMouse = PanelPlacement.frame(size: Self.size, anchor: PanelPlacement.pointAnchor(CGPoint(x: -1000, y: 700)),
                                           visibleFrame: leftScreen)
        #expect(atMouse.side == .right && leftScreen.contains(atMouse.frame) && atMouse.frame.minX > -1000)
        let corner = PanelPlacement.frame(size: Self.size, anchor: PanelPlacement.pointAnchor(CGPoint(x: -5, y: 125)),
                                          visibleFrame: leftScreen)
        #expect(corner.side == .left && leftScreen.contains(corner.frame))
        let above = CGRect(x: 0, y: 900, width: 2560, height: 1440)
        let frames = [screen, leftScreen, above]
        #expect(PanelPlacement.screenIndex(for: CGPoint(x: -10, y: 500), frames: frames) == 1)
        #expect(PanelPlacement.screenIndex(for: CGPoint(x: 100, y: 1500), frames: frames) == 2)
        // Off every screen: the nearest (the wide screen above main reaches x 2560).
        #expect(PanelPlacement.screenIndex(for: CGPoint(x: 5000, y: 100), frames: frames) == 2)
        #expect(PanelPlacement.screenIndex(for: CGPoint(x: 1500, y: -50), frames: frames) == 0)
        #expect(PanelPlacement.screenIndex(for: .zero, frames: []) == nil)
        #expect(PanelPlacement.height(for: 2_000, visibleFrame: screen) == 540)            // 60 % of the screen
        #expect(PanelPlacement.height(for: 100, visibleFrame: screen) == PanelPlacement.minHeight)
        let base = CGRect(x: 1000, y: 100, width: 420, height: 300)
        #expect(PanelPlacement.cascade(base, index: 0, visibleFrame: screen) == base)
        let third = PanelPlacement.cascade(base, index: 2, visibleFrame: screen)
        #expect(third == CGRect(x: 1020, y: 52, width: 420, height: 300))                  // clamped at the right edge
        #expect(PanelPlacement.width == 420 && PanelPlacement.maxHeight == 560 && PanelPlacement.cascadeStep == 24)
    }

    @Test func picksTheScreenShowingMostOfTheSelection() {
        let screens: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 875)),
            (CGRect(x: -1920, y: -180, width: 1920, height: 1080), CGRect(x: -1920, y: -180, width: 1920, height: 1055)),
        ]
        #expect(PanelPlacement.visibleFrame(for: CGRect(x: -300, y: 100, width: 400, height: 100), screens: screens) == screens[1].visible)
        #expect(PanelPlacement.visibleFrame(for: CGRect(x: -50, y: 100, width: 400, height: 100), screens: screens) == screens[0].visible)
        // Off every screen: the nearest.
        #expect(PanelPlacement.visibleFrame(for: CGRect(x: 3000, y: 100, width: 10, height: 10), screens: screens) == screens[0].visible)
        #expect(PanelPlacement.visibleFrame(for: .zero, screens: []) == nil)
    }
}
