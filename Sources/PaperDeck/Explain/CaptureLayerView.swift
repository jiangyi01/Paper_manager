import AppKit
import Observation
import SwiftUI
import PaperDeckCore

/// One display's frame / lens state (the overlay controller makes one per display).
@Observable
final class CaptureLayerModel {
    let displayID: CGDirectDisplayID
    /// The display's size in points (the overlay view's size).
    let size: CGSize
    /// The frozen still of this display (nil while the screen is being frozen).
    var still: FrozenDisplay?
    /// The mouse over this display (display-local points), nil when it is elsewhere.
    var cursor: CGPoint?
    /// The drag in progress (display-local points).
    var dragStart: CGPoint?
    var dragEnd: CGPoint?
    var zoom: CGFloat = CaptureGesture.defaultZoom

    init(displayID: CGDirectDisplayID, size: CGSize, still: FrozenDisplay? = nil) {
        self.displayID = displayID
        self.size = size
        self.still = still
    }

    /// The box being drawn (nil before a drag or while it is still a click).
    var box: CGRect? {
        guard let a = dragStart, let b = dragEnd else { return nil }
        let r = CaptureGesture.box(from: a, to: b, displaySize: size)
        return CaptureGeometry.isClick(r) ? nil : r
    }
}

/// The frame and lens over one display's frozen still (dive-capture §2, LN §4.4): the still itself
/// (what is cropped is what the user sees), a light dim with the box cut out, the box's border and
/// size, and in the lens mode a magnifier with a crosshair that follows the mouse (the scroll wheel
/// zooms 1.5×–6×). ⌥ marks the capture as a figure, ⇧ a click as a term. A transparent AppKit view
/// on top takes the mouse (its tracking area works while PaperDeck isn't the active app) and reports
/// to the overlay controller, which owns the gesture's consent and the crop. Hovering captures
/// nothing and costs no permission: the still was taken once when the overlay opened.
/// Phase-3 integration (Lead): the `CaptureOverlayController.captureLayer` hook.
struct CaptureLayerView: View {
    let layer: CaptureLayerModel
    let overlay: CaptureOverlayModel
    /// Reports the gestures (nil in renders: a picture only).
    var controller: CaptureOverlayController?

    static let dim = 0.18

    var body: some View {
        ZStack(alignment: .topLeading) {
            if overlay.captureAllowed, !overlay.freezeFailed {
                if let still = layer.still {
                    Image(decorative: still.image, scale: still.pixelScale.x)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: layer.size.width, height: layer.size.height)
                    DimWithCutout(size: layer.size, cutout: layer.box)
                        .fill(Color.black.opacity(Self.dim), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }
                if let box = layer.box {
                    BoxOutline(box: box, displaySize: layer.size, figure: overlay.optionHeld)
                } else if let cursor = layer.cursor {
                    if overlay.mode == .lens, let still = layer.still {
                        Lens(still: still, size: layer.size, cursor: cursor, zoom: layer.zoom)
                    } else {
                        Crosshair(arm: 9, gap: 3).position(cursor).allowsHitTesting(false)
                    }
                    if overlay.optionHeld || overlay.shiftHeld {
                        GestureBadge(text: overlay.optionHeld ? L.Explain.asFigure : L.Explain.asTerm)
                            .position(x: cursor.x + 44, y: cursor.y + (overlay.mode == .lens ? CaptureGesture.lensDiameter / 2 + 16 : 22))
                            .allowsHitTesting(false)
                    }
                }
                if let controller {
                    CaptureEventCatcher(layer: layer, controller: controller)
                        .frame(width: layer.size.width, height: layer.size.height)
                }
            }
        }
        .frame(width: layer.size.width, height: layer.size.height, alignment: .topLeading)
    }
}

/// The dim over the whole display with the box cut out (even-odd).
private struct DimWithCutout: Shape {
    let size: CGSize
    let cutout: CGRect?

    func path(in rect: CGRect) -> Path {
        var p = Path(CGRect(origin: .zero, size: size))
        if let cutout { p.addRect(cutout) }
        return p
    }
}

/// The box's border (the accent colour over a white halo, so it shows on light and dark pages) and its size.
private struct BoxOutline: View {
    let box: CGRect
    let displaySize: CGSize
    let figure: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(Color.white.opacity(0.9), lineWidth: 3.5)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            let label = figure ? CaptureGesture.sizeLabel(box) + " · " + L.Explain.asFigure : CaptureGesture.sizeLabel(box)
            let labelSize = CGSize(width: CGFloat(label.count) * 7.4 + 14, height: 20)
            let origin = CaptureGesture.labelOrigin(for: box, label: labelSize, displaySize: displaySize)
            Text(verbatim: label)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: labelSize.height)
                .background(Color.black.opacity(0.62), in: Capsule())
                .fixedSize()
                .offset(x: origin.x, y: origin.y)
        }
        .allowsHitTesting(false)
    }
}

/// The magnifier: the still drawn `zoom` times larger, clipped to a circle centred on the cursor,
/// with a ring and a crosshair whose centre is the point a click explains.
private struct Lens: View {
    let still: FrozenDisplay
    let size: CGSize
    let cursor: CGPoint
    let zoom: CGFloat

    var body: some View {
        let d = CaptureGesture.lensDiameter
        let offset = CaptureGesture.lensOffset(at: cursor, zoom: zoom)
        ZStack {
            Image(decorative: still.image, scale: still.pixelScale.x)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width * zoom, height: size.height * zoom)
                .offset(x: offset.width, y: offset.height)
                .frame(width: d, height: d, alignment: .topLeading)
                .clipShape(Circle())
            Circle().stroke(Color.black.opacity(0.35), lineWidth: 4)
            Circle().stroke(Color.white, lineWidth: 2)
            Crosshair(arm: 12, gap: 6)
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .overlay(alignment: .bottomTrailing) {
            Text(verbatim: String(format: "%.1f×", zoom))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.55), in: Capsule())
                .offset(x: 4, y: 4)
        }
        .position(cursor)
        .allowsHitTesting(false)
    }
}

/// Two short lines with a gap at the centre (dark over a white halo: visible on paper and on dark apps).
private struct Crosshair: View {
    let arm: CGFloat
    let gap: CGFloat

    var body: some View {
        ZStack {
            lines.stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            lines.stroke(Color(white: 0.08), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: 2 * (arm + gap), height: 2 * (arm + gap))
    }

    private var lines: Path {
        let c = arm + gap
        var p = Path()
        p.move(to: CGPoint(x: 0, y: c)); p.addLine(to: CGPoint(x: arm, y: c))
        p.move(to: CGPoint(x: c + gap, y: c)); p.addLine(to: CGPoint(x: 2 * c, y: c))
        p.move(to: CGPoint(x: c, y: 0)); p.addLine(to: CGPoint(x: c, y: arm))
        p.move(to: CGPoint(x: c, y: c + gap)); p.addLine(to: CGPoint(x: c, y: 2 * c))
        return p
    }
}

/// "As a figure" (⌥) / "A term" (⇧) next to the cursor.
private struct GestureBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: Capsule())
            .fixedSize()
    }
}

// MARK: - The mouse

/// The transparent AppKit view that takes the overlay's mouse: down / drag / up for the box and
/// the click, moves for the lens (a tracking area that works while PaperDeck isn't active), the
/// scroll wheel for the zoom, a right click to cancel.
private struct CaptureEventCatcher: NSViewRepresentable {
    let layer: CaptureLayerModel
    let controller: CaptureOverlayController

    func makeNSView(context: Context) -> CaptureEventView {
        let v = CaptureEventView()
        v.layerModel = layer
        v.controller = controller
        return v
    }

    func updateNSView(_ view: CaptureEventView, context: Context) {
        view.layerModel = layer
        view.controller = controller
    }
}

final class CaptureEventView: NSView {
    weak var layerModel: CaptureLayerModel?
    weak var controller: CaptureOverlayController?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect,
                                                         .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseEntered(with event: NSEvent) {
        layerModel?.cursor = local(event)
        controller?.modifiersChanged(event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) { layerModel?.cursor = nil }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()                      // best effort: the app below may set its own
        let p = local(event)
        layerModel?.cursor = p
        controller?.modifiersChanged(event.modifierFlags)
        if let layer = layerModel { controller?.pointerMoved(p, on: layer.displayID) }   // the HUD steps aside
    }

    override func mouseDown(with event: NSEvent) {
        let p = local(event)
        layerModel?.cursor = p
        layerModel?.dragStart = p
        layerModel?.dragEnd = p
    }

    override func mouseDragged(with event: NSEvent) {
        let p = local(event)
        layerModel?.cursor = p
        layerModel?.dragEnd = p
        controller?.modifiersChanged(event.modifierFlags)
        controller?.dragChanged(layerModel?.box != nil)                                 // the HUD hides
    }

    override func mouseUp(with event: NSEvent) {
        guard let layer = layerModel, let start = layer.dragStart else { return }
        let end = local(event)
        layer.dragStart = nil
        layer.dragEnd = nil
        let flags = event.modifierFlags
        let outcome = CaptureGesture.release(from: start, to: end, option: flags.contains(.option), shift: flags.contains(.shift),
                                             displaySize: layer.size)
        controller?.released(outcome, on: layer.displayID)
    }

    override func rightMouseDown(with event: NSEvent) { controller?.dismiss() }

    override func scrollWheel(with event: NSEvent) {
        guard let layer = layerModel else { return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        layer.zoom = CaptureGesture.zoom(layer.zoom, scrolledBy: dy)
    }
}
