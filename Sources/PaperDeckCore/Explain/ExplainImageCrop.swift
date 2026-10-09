import CoreGraphics
import Foundation

/// What the overlay sends for a released box or a click, made from the frozen still off the main
/// thread (CUX-7): the click's plan and its ink map, the crop, the blank check, the downscale and PNG
/// encode, the OCR copy. The overlay's main thread only reads the window under the capture before
/// (`probe`) and opens the panel after; closing the overlay cancels the work (nothing is sent). Pure
/// — synthetic stills in the tests, never a screen.
package enum ExplainImageCrop {
    /// What the user chose on the still.
    package enum Gesture: Sendable, Equatable {
        /// A drawn box (display-local points); `figure`: ⌥ was held (send it as a figure).
        case box(CaptureRegion, figure: Bool)
        /// A click at a display-local point; ⇧ (`term`) explains the term under it, ⌥ (`figure`) the
        /// figure around it.
        case click(CGPoint, displayID: CGDirectDisplayID, term: Bool, figure: Bool)
    }

    /// A capture ready to open its panel with.
    package struct Prepared: Sendable {
        /// What the capture is of (display-local points): the box, the click's band or its figure.
        /// The panel opens beside it.
        package var region: CaptureRegion
        /// What `ocrImage` covers: `region`, or for a click's paragraph the larger area around the
        /// band read when the paragraph runs past it (`CaptureGeometry.readArea`, inside the window
        /// under the click, CUX-8). The privacy check reads every window in it.
        package var readArea: CaptureRegion
        package var kind: ExplainTurnKind
        /// A click's focus (fractions of `readArea`); nil for a box or a figure.
        package var focus: ExplainFocus?
        /// The click (display-local points); nil for a box.
        package var click: CGPoint?
        /// The image a turn may send: `region`, downscaled and encoded.
        package var image: AssistImage
        /// `readArea` at full resolution for local OCR only, in its own bitmap (the still isn't kept).
        package var ocrImage: CGImage

        /// The capture reads beyond the region the panel opens beside (its windows must be checked too).
        package var readsBeyondRegion: Bool { readArea.rect != region.rect }
    }

    package enum Outcome: Sendable {
        case ready(Prepared)
        /// Nothing legible under or near the click on a page that has content: say so, send nothing.
        case nothingLegible
        /// The capture is one flat colour — protected (DRM) content or a sleeping display: say so,
        /// send nothing.
        case blank
        /// The still couldn't be cropped or encoded (an unknown display, an empty crop).
        case failed
        /// The overlay closed meanwhile: nothing.
        case cancelled
    }

    /// The global (Quartz) point whose window names the capture's app and title and bounds a click's
    /// band: the click, else the box's centre. nil for a display not in the still.
    package static func probe(_ gesture: Gesture, in s: FrozenScreens) -> CGPoint? {
        switch gesture {
        case .box(let r, _):
            return CaptureGeometry.global(r, in: s).map { CGPoint(x: $0.midX, y: $0.midY) }
        case .click(let p, let id, _, _):
            return s.display(id).map { CGPoint(x: p.x + $0.frame.minX, y: p.y + $0.frame.minY) }
        }
    }

    /// `prepare` off the caller's actor: the overlay awaits it from the main actor, and cancelling
    /// the awaiting task (the overlay closed) stops it between steps.
    @concurrent
    package static func run(_ gesture: Gesture, window: CGRect?, frozen: FrozenScreens) async -> Outcome {
        prepare(gesture, window: window, frozen: frozen) { Task.isCancelled }
    }

    /// The capture for `gesture` on `frozen`; `window`: the bounds of the window under the probe point
    /// (global Quartz points) — a click's band and read area stay inside it (F3). `cancelled` is asked
    /// between the steps.
    package static func prepare(_ gesture: Gesture, window: CGRect?, frozen: FrozenScreens,
                                cancelled: () -> Bool = { false }) -> Outcome {
        let region: CaptureRegion, readArea: CaptureRegion, kind: ExplainTurnKind, focus: ExplainFocus?, click: CGPoint?
        switch gesture {
        case .box(let r, let figure):
            guard frozen.display(r.displayID) != nil else { return .failed }
            (region, readArea, kind, focus, click) = (r, r, figure ? .figure : .explain, nil, nil)
        case .click(let p, let id, let term, let figure):
            guard let d = frozen.display(id) else { return .failed }
            let under = window.map { $0.standardized.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY) }
            let crop = { (r: CGRect) in CaptureGeometry.crop(frozen, CaptureRegion(displayID: id, rect: r)) }
            let plan = CaptureClickPlan.plan(click: p, displaySize: d.frame.size, window: under, term: term, figure: figure, crop: crop)
            if cancelled() { return .cancelled }
            switch plan {
            case .paragraph(let band, let f)?:
                let area = CaptureGeometry.readArea(band: band, click: p, displaySize: d.frame.size, window: under)
                (region, readArea, kind, focus, click) = (CaptureRegion(displayID: id, rect: band), CaptureRegion(displayID: id, rect: area),
                                                         term ? .defineTerms : .explain, f.widened(from: band, to: area), p)
            case .figure(let rect)?:
                let r = CaptureRegion(displayID: id, rect: rect)
                (region, readArea, kind, focus, click) = (r, r, .figure, nil, p)
            case .blank?:
                // Nothing under or near the click. All of the area around it one flat colour: a
                // protected window or a sleeping display; else an empty margin of a page.
                let around = CaptureGeometry.clip(CaptureGeometry.band(around: p, displaySize: d.frame.size, size: CaptureGeometry.readBand),
                                                  toWindow: under, keeping: p)
                let flat = crop(around).map(ExplainImage.isBlank) ?? false
                return flat ? .blank : .nothingLegible
            case nil:
                return .failed
            }
        }
        guard let crop = CaptureGeometry.crop(frozen, region) else { return .failed }
        // A flat box (a protected window, a sleeping display) is never sent (CUX-8); a click's plan
        // already found ink under it.
        if focus == nil, ExplainImage.isBlank(crop) { return .blank }
        if cancelled() { return .cancelled }
        guard let image = ExplainImageEncoder.encode(crop) else { return .failed }
        if cancelled() { return .cancelled }
        guard let read = readArea == region ? crop : CaptureGeometry.crop(frozen, readArea) else { return .failed }
        let ocrImage = copyFreesTheStill(read, of: frozen.display(readArea.displayID)) ? (ExplainImage.detached(read) ?? read) : read
        if cancelled() { return .cancelled }
        return .ready(Prepared(region: region, readArea: readArea, kind: kind, focus: focus, click: click, image: image,
                               ocrImage: ocrImage))
    }

    /// A crop of at most half of its display's still: copied out (`ExplainImage.detached`), it lets the
    /// still go with the overlay. A larger one (a full-screen box) keeps the still's pixels: the copy
    /// would hold about as much, for a 60 MB copy.
    static func copyFreesTheStill(_ crop: CGImage, of display: FrozenDisplay?) -> Bool {
        guard let d = display else { return false }
        return 2 * crop.width * crop.height <= d.image.width * d.image.height
    }
}
