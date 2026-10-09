import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// Multi-display geometry (LN §10 "Geometry"): a Retina main display, a 1× display to its left
/// (negative x) and a 2× display above it (negative y); crops snapped to the pixel grid; the
/// capture flow never asks for permission and never freezes without it (fakes only — nothing here
/// touches the screen).
@Suite struct CaptureGeometryTests {
    /// main: 1440×900 pt @2x at the origin; left: 1920×1080 pt @1x at x −1920 (lower: y 100);
    /// top: 1280×800 pt @2x above main (y −800).
    static func screens() throws -> FrozenScreens {
        let main = try #require(ExplainKit.coordinateImage(width: 2880, height: 1800))
        let left = try #require(ExplainKit.coordinateImage(width: 1920, height: 1080))
        let top = try #require(ExplainKit.coordinateImage(width: 2560, height: 1600))
        return FrozenScreens(displays: [
            FrozenDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2, image: main),
            FrozenDisplay(id: 2, frame: CGRect(x: -1920, y: 100, width: 1920, height: 1080), scale: 1, image: left),
            FrozenDisplay(id: 3, frame: CGRect(x: 80, y: -800, width: 1280, height: 800), scale: 2, image: top),
        ])
    }

    @Test func cropsAreRetinaScaledAndSnappedToThePixelGrid() throws {
        let s = try Self.screens()
        // Main @2x: (10.25, 20.75) pt → pixels (20.5, 41.5) → snapped outward to (20, 41).
        let crop = try #require(CaptureGeometry.crop(s, CaptureRegion(displayID: 1, rect: CGRect(x: 10.25, y: 20.75, width: 100, height: 50))))
        #expect(crop.width == 201 && crop.height == 101)
        #expect(ExplainKit.topLeft(crop).map { [$0.0, $0.1] } == [20, 41])
        // The 1x display left of main: points are pixels.
        let left = try #require(CaptureGeometry.crop(s, CaptureRegion(displayID: 2, rect: CGRect(x: 300, y: 7, width: 64, height: 32))))
        #expect(left.width == 64 && left.height == 32)
        #expect(ExplainKit.topLeft(left).map { [$0.0, $0.1] } == [300 % 256, 7])
        // Above main @2x.
        let top = try #require(CaptureGeometry.crop(s, CaptureRegion(displayID: 3, rect: CGRect(x: 5, y: 3, width: 10, height: 10))))
        #expect(top.width == 20 && top.height == 20 && ExplainKit.topLeft(top).map { [$0.0, $0.1] } == [10, 6])
        // Whole-point rects at 2x are exactly twice as large (no stray pixel).
        let exact = try #require(CaptureGeometry.crop(s, CaptureRegion(displayID: 1, rect: CGRect(x: 10, y: 10, width: 10, height: 10))))
        #expect(exact.width == 20 && exact.height == 20)
        // Clamped to the still; an unknown display or a rect off the display crops nothing.
        let edge = try #require(CaptureGeometry.crop(s, CaptureRegion(displayID: 1, rect: CGRect(x: 1400, y: 880, width: 100, height: 100))))
        #expect(edge.width == 80 && edge.height == 40)
        #expect(CaptureGeometry.crop(s, CaptureRegion(displayID: 9, rect: CGRect(x: 0, y: 0, width: 10, height: 10))) == nil)
        #expect(CaptureGeometry.crop(s, CaptureRegion(displayID: 1, rect: CGRect(x: 2000, y: 0, width: 10, height: 10))) == nil)
        // A still whose size disagrees with frame × scale still maps proportionally.
        let odd = FrozenScreens(displays: [FrozenDisplay(id: 4, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2,
                                                         image: try #require(ExplainKit.coordinateImage(width: 150, height: 150)))])
        let c = try #require(CaptureGeometry.crop(odd, CaptureRegion(displayID: 4, rect: CGRect(x: 10, y: 10, width: 20, height: 20))))
        #expect(c.width == 30 && ExplainKit.topLeft(c).map { [$0.0, $0.1] } == [15, 15])
    }

    @Test func regionsMapToGlobalPointsAndTinyDragsAreClicks() throws {
        let s = try Self.screens()
        // A region on the display above main, in global (Quartz) points; an unknown display has none.
        let up = CaptureRegion(displayID: 3, rect: CGRect(x: 420, y: 0, width: 200, height: 700))
        #expect(CaptureGeometry.global(up, in: s) == CGRect(x: 500, y: -800, width: 200, height: 700))
        #expect(CaptureGeometry.global(CaptureRegion(displayID: 9, rect: up.rect), in: s) == nil)
        #expect(CaptureGeometry.isClick(CGRect(x: 0, y: 0, width: 7.9, height: 50)))
        #expect(!CaptureGeometry.isClick(CGRect(x: 0, y: 0, width: 8, height: 8)))
    }

    @Test func cocoaAndQuartzConvert() {
        // Main 900 pt high: Cocoa (100, 850) is Quartz (100, 50); a display above main has Cocoa y > 900.
        #expect(CaptureGeometry.quartz(fromCocoa: CGPoint(x: 100, y: 850), mainHeight: 900) == CGPoint(x: 100, y: 50))
        #expect(CaptureGeometry.quartz(fromCocoa: CGPoint(x: 500, y: 910), mainHeight: 900) == CGPoint(x: 500, y: -10))
        let cocoa = CGRect(x: -1920, y: -280, width: 1920, height: 1080)         // the left display in Cocoa
        #expect(CaptureGeometry.quartz(fromCocoa: cocoa, mainHeight: 900) == CGRect(x: -1920, y: 100, width: 1920, height: 1080))
        let q = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(CaptureGeometry.cocoa(fromQuartz: CaptureGeometry.quartz(fromCocoa: q, mainHeight: 900), mainHeight: 900) == q)
        #expect(CaptureGeometry.cocoa(fromQuartz: CGPoint(x: 1, y: 2), mainHeight: 900) == CGPoint(x: 1, y: 898))
    }

    @Test func clickBandsStayOnTheDisplay() {
        let size = CGSize(width: 1440, height: 900)
        #expect(CaptureGeometry.band(around: CGPoint(x: 720, y: 450), displaySize: size) == CGRect(x: 370, y: 270, width: 700, height: 360))
        #expect(CaptureGeometry.band(around: CGPoint(x: 10, y: 10), displaySize: size) == CGRect(x: 0, y: 0, width: 700, height: 360))
        #expect(CaptureGeometry.band(around: CGPoint(x: 1435, y: 895), displaySize: size) == CGRect(x: 740, y: 540, width: 700, height: 360))
        #expect(CaptureGeometry.band(around: CGPoint(x: 50, y: 50), displaySize: CGSize(width: 300, height: 200))
                == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func snapGrowsOutwardButNotForRoundingNoise() {
        let b = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CaptureGeometry.snap(CGRect(x: 1.5, y: 2.5, width: 3, height: 3), within: b) == CGRect(x: 1, y: 2, width: 4, height: 4))
        #expect(CaptureGeometry.snap(CGRect(x: 2.0000000001, y: 0, width: 19.9999999998, height: 10), within: b)
                == CGRect(x: 2, y: 0, width: 20, height: 10))
        #expect(CaptureGeometry.snap(CGRect(x: 200, y: 0, width: 5, height: 5), within: b) == .zero)
    }

    static func failure(_ r: Result<FrozenScreens, CaptureError>) -> CaptureError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    static func counts(_ f: ExplainKit.FakeCapturer) -> [Int] { [f.counts.preflights, f.counts.requests, f.counts.freezes] }

    @Test func theFlowFreezesOnlyWithPermissionAndNeverAsks() async throws {
        let denied = ExplainKit.FakeCapturer(granted: false)
        #expect(Self.failure(await CaptureFlow.freeze(denied, excluding: [11, 12])) == .permissionDenied)
        #expect(Self.counts(denied) == [1, 0, 0])            // preflighted, never requested, never frozen
        let screens = try Self.screens()
        let granted = ExplainKit.FakeCapturer(granted: true, screens: screens)
        guard case .success(let s) = await CaptureFlow.freeze(granted, excluding: [11, 12]) else { Issue.record("no stills"); return }
        #expect(s.displays.map(\.id) == [1, 2, 3])
        #expect(Self.counts(granted) == [1, 0, 1] && granted.freezes == [[11, 12]])
        let none = ExplainKit.FakeCapturer(granted: true)
        #expect(Self.failure(await CaptureFlow.freeze(none, excluding: [])) == .noDisplays)
        let revoked = ExplainKit.FakeCapturer(granted: true, failure: .permissionDenied)
        #expect(Self.failure(await CaptureFlow.freeze(revoked, excluding: [])) == .permissionDenied)
        #expect(revoked.counts.requests == 0)
    }
}
