import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// The exact page + rect anchor the reader hands to Explain, and where its floating toolbars sit.
@Suite("Reader: anchors and overlay placement")
struct ReaderAnchorTests {
    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let id = "8b0c4e6a-1111-4222-8333-944455556666"

    @Test func aDragBecomesARegionWhicheverWayItWasDrawn() throws {
        let down = try #require(ReaderAnchor.region(paperID: Self.id, page: 4, from: CGPoint(x: 100, y: 500),
                                                    to: CGPoint(x: 300, y: 380), pageBounds: Self.letter))
        let up = try #require(ReaderAnchor.region(paperID: Self.id, page: 4, from: CGPoint(x: 300, y: 380),
                                                  to: CGPoint(x: 100, y: 500), pageBounds: Self.letter))
        #expect(down.rect == CGRect(x: 100, y: 380, width: 200, height: 120))
        #expect(up == down)
        #expect(down.kind == .region && down.page == 4 && down.paperID == Self.id)
    }

    @Test func aRegionIsClippedToThePageAndAClickIsNoRegion() throws {
        let off = try #require(ReaderAnchor.region(paperID: Self.id, page: 1, from: CGPoint(x: -50, y: 700),
                                                   to: CGPoint(x: 80, y: 900), pageBounds: Self.letter))
        #expect(off.rect == CGRect(x: 0, y: 700, width: 80, height: 92))
        #expect(ReaderAnchor.region(paperID: Self.id, page: 1, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 15, y: 40),
                                    pageBounds: Self.letter) == nil, "narrower than minSide")
        #expect(ReaderAnchor.region(paperID: Self.id, page: 1, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10),
                                    pageBounds: Self.letter) == nil, "a click")
        #expect(ReaderAnchor.region(paperID: Self.id, page: 1, from: CGPoint(x: 700, y: 10), to: CGPoint(x: 900, y: 300),
                                    pageBounds: Self.letter) == nil, "entirely off the page")
        // Exactly minSide is a region.
        #expect(ReaderAnchor.region(paperID: Self.id, page: 1, from: .zero, to: CGPoint(x: 8, y: 8), pageBounds: Self.letter) != nil)
    }

    @Test func theUnitRectSurvivesAPageOfAnotherSize() throws {
        let cropped = CGRect(x: 18, y: 36, width: 576, height: 720)
        let a = try #require(ReaderAnchor.region(paperID: Self.id, page: 2, from: CGPoint(x: 162, y: 216),
                                                 to: CGPoint(x: 450, y: 576), pageBounds: cropped))
        let unit = a.unitRect
        #expect(abs(unit.minX - 0.25) < 1e-9 && abs(unit.minY - 0.25) < 1e-9)
        #expect(abs(unit.width - 0.5) < 1e-9 && abs(unit.height - 0.5) < 1e-9)
        let back = ReaderAnchor.rect(unit: unit, in: cropped)
        #expect(abs(back.minX - a.rect.minX) < 1e-9 && abs(back.maxY - a.rect.maxY) < 1e-9)
        let a4 = ReaderAnchor.rect(unit: unit, in: CGRect(x: 0, y: 0, width: 595, height: 842))
        #expect(abs(a4.width - 297.5) < 1e-9 && abs(a4.height - 421) < 1e-9)
        let degenerate = ReaderAnchor(paperID: Self.id, kind: .region, page: 1, rect: a.rect, pageBounds: .zero)
        #expect(degenerate.unitRect == .zero)
    }

    @Test func anAnchorRoundTripsThroughJSONAndCapsItsText() throws {
        let long = String(repeating: "word ", count: 600)
        let a = ReaderAnchor(paperID: Self.id, kind: .selection, page: 0, printedLabel: "1203",
                             rect: CGRect(x: 300, y: 400, width: -100, height: -20), pageBounds: Self.letter, text: "  \(long)  ")
        #expect(a.page == 1, "pages are 1-based")
        #expect(a.rect == CGRect(x: 200, y: 380, width: 100, height: 20), "standardized")
        #expect(a.text?.count == ReaderAnchor.maxText && a.text?.hasPrefix("word") == true)
        let back = try JSONDecoder().decode(ReaderAnchor.self, from: JSONEncoder().encode(a))
        #expect(back == a)
        #expect(ReaderAnchor(paperID: Self.id, kind: .region, page: 1, rect: .zero, pageBounds: Self.letter, text: " \n ").text == nil)
    }

    @Test func aRegionRendersSharpButWithinTheImageCap() {
        // A small box: 3× (the sharpest we go).
        #expect(ReaderAnchor.renderScale(for: CGRect(x: 0, y: 0, width: 200, height: 120)) == 3)
        // A whole Letter page: the long edge (792 pt) fits 1568 px.
        let page = ReaderAnchor.renderScale(for: Self.letter)
        #expect(abs(page - 1568.0 / 792.0) < 1e-9)
        let px = ReaderAnchor.pixelSize(for: Self.letter, scale: page)
        #expect(px.height == 1568 && px.width == 1212)
        #expect(max(px.width, px.height) <= AssistImage.maxLongEdge)
        // A huge box goes below 1× rather than past the cap.
        #expect(ReaderAnchor.renderScale(for: CGRect(x: 0, y: 0, width: 3000, height: 100)) < 1)
        #expect(ReaderAnchor.renderScale(for: .zero) == 1)
        #expect(ReaderAnchor.pixelSize(for: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), scale: 1) == CGSize(width: 1, height: 1))
    }

    // MARK: Overlay placement (origin top-left)

    static let viewport = CGSize(width: 800, height: 600)
    static let bar = CGSize(width: 240, height: 32)

    @Test func theToolbarSitsAboveItsTargetWhenThereIsRoom() throws {
        let c = try #require(ReaderOverlayPlacement.toolbarCenter(target: CGRect(x: 300, y: 200, width: 200, height: 40),
                                                                   toolbar: Self.bar, viewport: Self.viewport))
        #expect(c == CGPoint(x: 400, y: 200 - 8 - 16))
    }

    @Test func nearTheTopItGoesBelowAndNearTheEdgesItStaysInside() throws {
        let below = try #require(ReaderOverlayPlacement.toolbarCenter(target: CGRect(x: 300, y: 20, width: 200, height: 40),
                                                                       toolbar: Self.bar, viewport: Self.viewport))
        #expect(below == CGPoint(x: 400, y: 60 + 8 + 16))
        let left = try #require(ReaderOverlayPlacement.toolbarCenter(target: CGRect(x: 0, y: 300, width: 40, height: 20),
                                                                      toolbar: Self.bar, viewport: Self.viewport))
        #expect(left.x == CGFloat(8 + 120))
        let right = try #require(ReaderOverlayPlacement.toolbarCenter(target: CGRect(x: 780, y: 300, width: 40, height: 20),
                                                                       toolbar: Self.bar, viewport: Self.viewport))
        #expect(right.x == CGFloat(800 - 8 - 120))
    }

    @Test func aTallTargetPinsTheToolbarToItsVisibleTopAndAnOffscreenOneHidesIt() throws {
        let tall = try #require(ReaderOverlayPlacement.toolbarCenter(target: CGRect(x: 100, y: -200, width: 400, height: 1000),
                                                                      toolbar: Self.bar, viewport: Self.viewport))
        #expect(tall.y == CGFloat(8 + 16))
        #expect(ReaderOverlayPlacement.toolbarCenter(target: CGRect(x: 100, y: -300, width: 200, height: 100),
                                                     toolbar: Self.bar, viewport: Self.viewport) == nil, "scrolled above")
        #expect(ReaderOverlayPlacement.toolbarCenter(target: CGRect(x: 100, y: 700, width: 200, height: 100),
                                                     toolbar: Self.bar, viewport: Self.viewport) == nil, "scrolled below")
        // A viewport narrower than the toolbar: centred.
        let narrow = try #require(ReaderOverlayPlacement.toolbarCenter(target: CGRect(x: 10, y: 300, width: 50, height: 20),
                                                                        toolbar: Self.bar, viewport: CGSize(width: 200, height: 600)))
        #expect(narrow.x == CGFloat(100))
    }
}
