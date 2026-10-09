import CoreGraphics
import Foundation

// Screen capture for Explain's frame and lens (dive-capture §3): the overlay freezes every display
// once (PaperDeck's own overlay / panel windows excluded), the user draws on the still, and the
// crop comes from the same pixels the user saw. The capturer itself lives in the App
// (`ScreenCapturer`, ScreenCaptureKit); Core holds the contract and the pure geometry, so tests use
// fakes and synthetic stills only — nothing here touches the screen or asks for permission.
//
// Coordinate spaces (all in points unless named "pixel"):
// - **global**: the Quartz display space — origin at the top-left of the main display, y down.
//   `SCDisplay.frame`, `CGDisplayBounds` and `CGWindowListCopyWindowInfo` bounds use it. A display
//   left of the main one has a negative x; one above it a negative y.
// - **Cocoa**: AppKit's global space — origin at the bottom-left of the main display, y up
//   (`NSEvent.mouseLocation`, `NSWindow.frame`, `NSScreen.frame`). `quartz(fromCocoa:)` converts.
// - **display-local**: origin at the display's top-left, y down (`CaptureRegion.rect`).
// - **pixel**: a display still's pixels (top-left origin), display-local × the display's scale.

/// The App's screen capturer (ScreenCaptureKit), injected so tests can use fakes.
package protocol ScreenCapturing: Sendable {
    /// Screen Recording is granted (never prompts).
    func preflight() -> Bool
    /// Asks for Screen Recording (the system prompt the first time). Only from an explicit button.
    func request() async -> Bool
    /// A still of every display, without the given (PaperDeck overlay / panel) windows.
    func freeze(excludingWindowIDs: [CGWindowID]) async throws -> FrozenScreens
}

/// Every display's still, taken at one moment.
package struct FrozenScreens: Sendable {
    package var displays: [FrozenDisplay]

    package init(displays: [FrozenDisplay]) { self.displays = displays }

    package func display(_ id: CGDirectDisplayID) -> FrozenDisplay? { displays.first { $0.id == id } }
}

/// One display's still.
package struct FrozenDisplay: Sendable {
    package var id: CGDirectDisplayID
    /// Global (Quartz) points.
    package var frame: CGRect
    /// Pixels per point (`SCContentFilter.pointPixelScale`: 2 on Retina, also in scaled modes).
    package var scale: CGFloat
    package var image: CGImage

    package init(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat, image: CGImage) {
        self.id = id; self.frame = frame; self.scale = scale; self.image = image
    }

    /// Pixels per point along x / y as captured (the still's size over the frame); `scale` when the
    /// frame is empty. Equal to `scale` for a normal capture; robust to a still that isn't.
    package var pixelScale: (x: CGFloat, y: CGFloat) {
        guard frame.width > 0, frame.height > 0 else { return (scale, scale) }
        let sx = CGFloat(image.width) / frame.width, sy = CGFloat(image.height) / frame.height
        return (sx > 0 ? sx : scale, sy > 0 ? sy : scale)
    }
}

/// A rectangle on one display, in display-local points.
package struct CaptureRegion: Sendable, Equatable {
    package var displayID: CGDirectDisplayID
    package var rect: CGRect

    package init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID; self.rect = rect.standardized
    }
}

/// Why a capture produced no still.
package enum CaptureError: Error, Sendable, Equatable {
    /// Screen Recording isn't granted (or the user declined it).
    case permissionDenied
    /// No display could be captured (one went to sleep, the list changed).
    case noDisplays
    case failed(String)
}

/// The capture flow's one safety rule in code: a still is taken only when Screen Recording is
/// already granted — the flow never asks (asking is `ScreenPermission`'s explicit button).
package enum CaptureFlow {
    package static func freeze(_ capturer: any ScreenCapturing,
                               excluding windowIDs: [CGWindowID]) async -> Result<FrozenScreens, CaptureError> {
        guard capturer.preflight() else { return .failure(.permissionDenied) }
        do {
            let screens = try await capturer.freeze(excludingWindowIDs: windowIDs)
            return screens.displays.isEmpty ? .failure(.noDisplays) : .success(screens)
        } catch let e as CaptureError {
            return .failure(e)
        } catch {
            return .failure(.failed(String(describing: type(of: error))))
        }
    }
}

package enum CaptureGeometry {
    /// A drag smaller than this (points, either side) is a click (`ReaderAnchor.minSide`).
    package static let clickSide: CGFloat = 8
    /// The band OCR'd around a click (frame mode) or a lens click (dive-capture §2), in points.
    package static let clickBand = CGSize(width: 700, height: 360)
    /// A click's capture also holds this much around the click (twice the band, inside the window
    /// under it), read once more when the paragraph under the click runs past the band (CUX-8).
    package static let readBand = CGSize(width: 1400, height: 720)

    // MARK: Contract

    /// The pixels of `r` on its display's still: display-local points × the display's scale,
    /// snapped outward to the pixel grid and clamped to the still. nil for an unknown display or an
    /// empty intersection.
    package static func crop(_ s: FrozenScreens, _ r: CaptureRegion) -> CGImage? {
        guard let d = s.display(r.displayID) else { return nil }
        let px = pixelRect(r.rect, in: d)
        guard px.width >= 1, px.height >= 1 else { return nil }
        return d.image.cropping(to: px)
    }

    // MARK: Spaces

    /// AppKit global (bottom-left origin, y up) → Quartz global. `mainHeight` is the main
    /// display's height (`NSScreen.screens[0].frame.height`).
    package static func quartz(fromCocoa p: CGPoint, mainHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainHeight - p.y)
    }

    package static func quartz(fromCocoa r: CGRect, mainHeight: CGFloat) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Quartz global → AppKit global (the same flip; it is its own inverse).
    package static func cocoa(fromQuartz p: CGPoint, mainHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainHeight - p.y)
    }

    package static func cocoa(fromQuartz r: CGRect, mainHeight: CGFloat) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    /// A display-local rect of `displayID` in global (Quartz) points.
    package static func global(_ r: CaptureRegion, in s: FrozenScreens) -> CGRect? {
        guard let d = s.display(r.displayID) else { return nil }
        return r.rect.offsetBy(dx: d.frame.minX, dy: d.frame.minY)
    }

    // MARK: Pixels

    /// `local` (display-local points) as a pixel rect of `d`'s still: snapped outward to whole
    /// pixels, clamped to the still (possibly empty).
    package static func pixelRect(_ local: CGRect, in d: FrozenDisplay) -> CGRect {
        let (sx, sy) = d.pixelScale
        let r = local.standardized
        let raw = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
        return snap(raw, within: CGRect(x: 0, y: 0, width: d.image.width, height: d.image.height))
    }

    /// Outward to whole pixels, then clamped to `bounds` (empty when they don't intersect).
    package static func snap(_ r: CGRect, within bounds: CGRect) -> CGRect {
        // A hair of tolerance so 2 × 10.0000001 doesn't grow a pixel.
        let e: CGFloat = 1e-6
        let minX = (r.minX + e).rounded(.down), minY = (r.minY + e).rounded(.down)
        let maxX = (r.maxX - e).rounded(.up), maxY = (r.maxY - e).rounded(.up)
        let snapped = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        let clipped = snapped.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }

    // MARK: Gestures

    /// A drag this small is a click (explain the block under the point).
    package static func isClick(_ rect: CGRect) -> Bool {
        let r = rect.standardized
        return r.width < clickSide || r.height < clickSide
    }

    /// The band OCR'd around a click at `local` (display-local), kept on the display: centred on
    /// the point, shifted inward at an edge, never larger than the display.
    package static func band(around local: CGPoint, displaySize: CGSize, size: CGSize = clickBand) -> CGRect {
        let w = min(size.width, displaySize.width), h = min(size.height, displaySize.height)
        let x = min(max(local.x - w / 2, 0), max(displaySize.width - w, 0))
        let y = min(max(local.y - h / 2, 0), max(displaySize.height - h, 0))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A click's band kept inside the window under the click (F3: another app's window beside it is
    /// never part of what is read or sent). `window` and the result are display-local; a window that
    /// doesn't hold the point (or none) leaves the band as it is.
    package static func clip(_ band: CGRect, toWindow window: CGRect?, keeping point: CGPoint) -> CGRect {
        guard let w = window?.standardized, w.contains(point) else { return band }
        let r = band.intersection(w)
        return r.isNull || r.width < 1 || r.height < 1 ? band : r
    }

    /// What a click's capture holds (CUX-8): its `band` and `readBand` around the click, kept inside
    /// the window under the click like the band (display-local points) — so a paragraph that runs
    /// past the band's edge is read once more without another capture, never past the window.
    package static func readArea(band: CGRect, click local: CGPoint, displaySize: CGSize, window: CGRect?) -> CGRect {
        clip(self.band(around: local, displaySize: displaySize, size: readBand), toWindow: window, keeping: local)
            .union(band.standardized)
    }

    /// Where a capture sits on screen (CUX-13: the overlay's geometry, pure): its global (Quartz)
    /// rect, the global point whose window names the app and title (the click, else the region's
    /// centre), and the AppKit rect the panel opens beside. nil for an unknown display.
    package struct Placement: Sendable, Equatable {
        package var global: CGRect
        package var probe: CGPoint
        package var near: CGRect
    }

    package static func placement(_ r: CaptureRegion, click local: CGPoint?, in s: FrozenScreens, mainHeight: CGFloat) -> Placement? {
        guard let d = s.display(r.displayID), let global = global(r, in: s) else { return nil }
        let probe = local.map { CGPoint(x: $0.x + d.frame.minX, y: $0.y + d.frame.minY) } ?? CGPoint(x: global.midX, y: global.midY)
        return Placement(global: global, probe: probe, near: cocoa(fromQuartz: global, mainHeight: mainHeight))
    }
}
