import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// CUX-5: the panel opens beside the selection and, as the answer streams in and it grows to its real
/// content height, keeps the side it went to and never covers the selection — near all four screen
/// edges, on the main display and on a secondary one left of / above it (negative origins).
@Suite struct PanelRefitTests {
    static let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    /// A display left of and below the main one's origin (Cocoa: negative x and y).
    static let secondary = CGRect(x: -1920, y: -300, width: 1920, height: 1055)

    /// Opens at 300 pt, then grows to `to` (each step as the content reports it).
    static func grow(_ anchor: CGRect, in vf: CGRect, to heights: [CGFloat]) -> [(frame: CGRect, side: PanelPlacement.Side)] {
        let size = CGSize(width: PanelPlacement.width, height: PanelPlacement.height(for: 300, visibleFrame: vf))
        var p = PanelPlacement.frame(size: size, anchor: anchor, visibleFrame: vf)
        var out = [p]
        for h in heights {
            p = PanelPlacement.refit(p.frame, side: p.side, anchor: anchor, height: PanelPlacement.height(for: h, visibleFrame: vf),
                                     visibleFrame: vf)
            out.append(p)
        }
        return out
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }

    static func onScreen(_ f: CGRect, _ vf: CGRect) -> Bool {
        f.minX >= vf.minX - 0.5 && f.maxX <= vf.maxX + 0.5 && f.minY >= vf.minY - 0.5 && f.maxY <= vf.maxY + 0.5
    }

    @Test func probeP11AFullWidthBoxNearTheBottomIsNeverCovered() {
        // A full-width box in the lower part of the screen: the panel goes above it and grows upward.
        let box = CGRect(x: 0, y: 100, width: 1440, height: 300)
        let steps = Self.grow(box, in: Self.main, to: [380, 460, 525, 900])
        #expect(steps[0].side == .above)
        for s in steps {
            #expect(!Self.overlaps(s.frame, box), "\(s)")
            #expect(Self.onScreen(s.frame, Self.main), "\(s)")
        }
        // It grew upward from the box's top (its bottom edge stays put), up to the screen's top.
        #expect(steps.allSatisfy { abs($0.frame.minY - steps[0].frame.minY) < 0.5 })
        #expect(steps[1].frame.height == 380 && steps[3].frame.maxY == Self.main.maxY)
        #expect(steps[3].frame.height == Self.main.maxY - steps[0].frame.minY)
    }

    @Test func everyEdgeOfBothDisplaysKeepsTheSelectionVisible() {
        for vf in [Self.main, Self.secondary] {
            let anchors: [String: CGRect] = [
                "top": CGRect(x: vf.midX - 300, y: vf.maxY - 160, width: 600, height: 120),
                "bottom": CGRect(x: vf.midX - 300, y: vf.minY + 20, width: 600, height: 120),
                "left": CGRect(x: vf.minX + 10, y: vf.midY - 100, width: 300, height: 200),
                "right": CGRect(x: vf.maxX - 310, y: vf.midY - 100, width: 300, height: 200),
                "bottom-right corner": CGRect(x: vf.maxX - 260, y: vf.minY + 10, width: 250, height: 60),
                "top-left corner": CGRect(x: vf.minX + 10, y: vf.maxY - 70, width: 250, height: 60),
                "wide, low": CGRect(x: vf.minX, y: vf.minY + 60, width: vf.width, height: 260),
                "wide, high": CGRect(x: vf.minX, y: vf.maxY - 320, width: vf.width, height: 260),
            ]
            for (name, a) in anchors {
                for s in Self.grow(a, in: vf, to: [360, 480, 560, 700]) {
                    #expect(Self.onScreen(s.frame, vf), "\(name) \(vf): \(s)")
                    if s.side != .inside { #expect(!Self.overlaps(s.frame, a), "\(name) \(vf): \(s)") }
                }
            }
        }
    }

    @Test func besideTheSelectionTheTopStaysUntilTheScreenBottom() {
        let a = CGRect(x: 100, y: 200, width: 300, height: 80)
        let first = PanelPlacement.frame(size: CGSize(width: 420, height: 300), anchor: a, visibleFrame: Self.main)
        #expect(first.side == .right)
        let grown = PanelPlacement.refit(first.frame, side: .right, anchor: a, height: 500, visibleFrame: Self.main)
        // The top would leave the panel below the screen: it moves up just enough, still beside the box.
        #expect(grown.side == .right && grown.frame.minY == Self.main.minY && grown.frame.height == 500)
        #expect(grown.frame.minX == first.frame.minX && !Self.overlaps(grown.frame, a))
        // Room enough: the top edge stays where it was.
        let high = CGRect(x: 100, y: 700, width: 300, height: 80)
        let f = PanelPlacement.frame(size: CGSize(width: 420, height: 300), anchor: high, visibleFrame: Self.main)
        let g = PanelPlacement.refit(f.frame, side: f.side, anchor: high, height: 450, visibleFrame: Self.main)
        #expect(g.frame.maxY == f.frame.maxY && g.frame.height == 450)
    }

    @Test func belowTheSelectionTheHeightIsCappedNotPushedOverIt() {
        // A wide box near the top: below it; growing past the room left caps the height.
        let a = CGRect(x: 0, y: 500, width: 1440, height: 300)
        let first = PanelPlacement.frame(size: CGSize(width: 420, height: 300), anchor: a, visibleFrame: Self.main)
        #expect(first.side == .below)
        let grown = PanelPlacement.refit(first.frame, side: .below, anchor: a, height: 560, visibleFrame: Self.main)
        #expect(grown.side == .below && grown.frame.maxY == first.frame.maxY && grown.frame.minY == Self.main.minY)
        #expect(grown.frame.height < 560 && !Self.overlaps(grown.frame, a))
    }

    @Test func tooLittleRoomOnItsSidePlacesThePanelAgain() {
        // Above a box with 230 pt left over it: a 500 pt panel can't fit there any more.
        let vf = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let a = CGRect(x: 0, y: 360, width: 1440, height: 300)
        let squeezed = PanelPlacement.refit(CGRect(x: 0, y: 672, width: 420, height: 200), side: .above, anchor: a, height: 500,
                                            visibleFrame: vf)
        // No side holds 500 pt now: the panel goes inside the selection's corner, on screen.
        #expect(squeezed.side == .inside && squeezed.frame.height == 500, "\(squeezed)")
        #expect(Self.onScreen(squeezed.frame, vf))
        // With room below instead, it moves there rather than over the selection.
        let low = CGRect(x: 0, y: 560, width: 1440, height: 120)
        let moved = PanelPlacement.refit(CGRect(x: 0, y: 692, width: 420, height: 180), side: .above, anchor: low, height: 500,
                                         visibleFrame: vf)
        #expect(moved.side == .below && !Self.overlaps(moved.frame, low) && Self.onScreen(moved.frame, vf), "\(moved)")
    }
}
