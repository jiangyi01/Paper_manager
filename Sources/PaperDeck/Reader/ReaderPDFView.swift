import AppKit
import PDFKit
import SwiftUI

/// The reader's `PDFView`: ordinary PDFKit reading (scroll, select, links, ⌘C), plus a box drawn by
/// ⌘-drag (or a plain drag in region mode) that becomes an exact page + rect anchor
/// (`ReaderModel.boxEnded`). The box and the toolbars are SwiftUI overlays; nothing is added to the
/// document. Owned by Slice C (reader).
final class ReaderPDFView: PDFView {
    weak var model: ReaderModel?
    private var boxing = false
    private var afterLayoutPending = false

    private func startsBox(_ event: NSEvent) -> Bool {
        guard document != nil else { return false }
        return event.modifierFlags.contains(.command) || model?.regionMode == true
    }

    override func mouseDown(with event: NSEvent) {
        if startsBox(event) {
            boxing = true
            model?.boxBegan(at: convert(event.locationInWindow, from: nil))
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard boxing else { return super.mouseDragged(with: event) }
        autoscroll(with: event)
        model?.boxMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard boxing else {
            super.mouseUp(with: event)
            model?.selectionSettled()
            return
        }
        boxing = false
        model?.boxEnded(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        if model?.regionMode == true || event.modifierFlags.contains(.command) {
            NSCursor.crosshair.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {                     // Esc: the box, the selection, then the find bar
            model?.escape()
            return
        }
        super.keyDown(with: event)
    }

    /// After a layout pass (never inside it: the model's overlays are SwiftUI state), once per turn.
    override func layout() {
        super.layout()
        guard !afterLayoutPending else { return }
        afterLayoutPending = true
        Task { [weak self] in
            self?.afterLayoutPending = false
            self?.model?.afterLayout()
        }
    }
}

/// Hosts the model's `PDFView` in SwiftUI.
struct ReaderPDFRepresentable: NSViewRepresentable {
    let model: ReaderModel

    func makeNSView(context: Context) -> ReaderPDFView { model.pdfView }
    func updateNSView(_ view: ReaderPDFView, context: Context) {}
}

/// The page thumbnails beside the page view (they follow and drive the same `PDFView`).
struct ReaderThumbnailsRepresentable: NSViewRepresentable {
    let model: ReaderModel

    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.thumbnailSize = CGSize(width: 92, height: 120)
        v.backgroundColor = .clear
        v.allowsDragging = false
        v.allowsMultipleSelection = false
        v.pdfView = model.pdfView
        return v
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== model.pdfView { view.pdfView = model.pdfView }
    }
}

/// A quote's highlight: highlight annotations on the in-memory document, one per line of the
/// selection, removed again when the reader moves on or closes. The reader never writes the
/// document, so the PDF file is never changed; PDFKit draws them like any highlight (scrolling,
/// zooming, thumbnails). Owned by Slice C (reader).
enum ReaderHighlight {
    struct Mark {
        let page: PDFPage
        let annotation: PDFAnnotation
    }

    static func add(_ selection: PDFSelection, color: NSColor, in view: PDFView? = nil) -> [Mark] {
        var marks: [Mark] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page).insetBy(dx: -1, dy: -1)
                guard b.width > 0, b.height > 0 else { continue }
                let a = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
                a.color = color
                a.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: b.height)), NSValue(point: NSPoint(x: b.width, y: b.height)),
                                         NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: b.width, y: 0))]
                page.addAnnotation(a)
                marks.append(Mark(page: page, annotation: a))
            }
        }
        refresh(marks, in: view)
        return marks
    }

    static func remove(_ marks: [Mark], in view: PDFView? = nil) {
        for m in marks { m.page.removeAnnotation(m.annotation) }
        refresh(marks, in: view)
    }

    /// The view redraws the pages whose annotations changed.
    private static func refresh(_ marks: [Mark], in view: PDFView?) {
        guard let view else { return }
        var seen = Set<ObjectIdentifier>()
        for m in marks where seen.insert(ObjectIdentifier(m.page)).inserted { view.annotationsChanged(on: m.page) }
    }
}
