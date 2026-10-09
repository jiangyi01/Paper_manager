import CoreGraphics
import Foundation

/// An exact place in a paper, from the built-in reader (LN §8: "saved explanations get anchors (page +
/// rect in page space)"): the physical page and a rectangle in that page's PDF space (points, the
/// page's own unrotated coordinates, origin at its media box origin, y up) — what a ⌘-drag box or a
/// text selection covers. The reader hands it to Explain (A4) with the exact text and, for a box, a
/// render of the region from the PDF itself; nothing here reads the screen. Owned by Slice C (reader).
package struct ReaderAnchor: Sendable, Equatable, Codable {
    package enum Kind: String, Sendable, Codable { case selection, region }

    package var paperID: String
    package var kind: Kind
    /// Physical, 1-based.
    package var page: Int
    /// The printed label of that page when it differs (`ReaderPages.printedLabel`).
    package var printedLabel: String?
    /// In page space (points).
    package var rect: CGRect
    /// The page's crop box when the anchor was made (for `unitRect`).
    package var pageBounds: CGRect
    /// The PDF's own text there (a selection's string, the text inside a box); nil when there is none
    /// (a figure, a scanned page).
    package var text: String?

    /// A box smaller than this (points, either side) is a click, not a region.
    package static let minSide: CGFloat = 8
    /// Stored / handed-over text is kept to this many characters (`ExplanationRecord.maxExcerpt`).
    package static let maxText = 2_000

    package init(paperID: String, kind: Kind, page: Int, printedLabel: String? = nil, rect: CGRect, pageBounds: CGRect,
                 text: String? = nil) {
        self.paperID = paperID; self.kind = kind; self.page = max(page, 1); self.printedLabel = printedLabel
        self.rect = rect.standardized; self.pageBounds = pageBounds.standardized
        self.text = Self.trimmed(text)
    }

    /// A ⌘-drag box from two corners in page space, clipped to the page; nil when what is left is
    /// smaller than `minSide` either way (a click, or a drag that stayed off the page).
    package static func region(paperID: String, page: Int, printedLabel: String? = nil, from a: CGPoint, to b: CGPoint,
                               pageBounds: CGRect, text: String? = nil) -> ReaderAnchor? {
        let drawn = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let clipped = drawn.intersection(pageBounds.standardized)
        guard !clipped.isNull, clipped.width >= minSide, clipped.height >= minSide else { return nil }
        return ReaderAnchor(paperID: paperID, kind: .region, page: page, printedLabel: printedLabel, rect: clipped,
                            pageBounds: pageBounds, text: text)
    }

    /// The rect relative to the page (0…1 each way), independent of the page's size — in the page's
    /// unrotated space, like `rect` (a page with /Rotate is shown turned: `ReaderPDF.displayTransform`
    /// maps a rect to its on-screen orientation, and `ReaderPDF.renderRegion` draws it that way).
    package var unitRect: CGRect {
        let b = pageBounds
        guard b.width > 0, b.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - b.minX) / b.width, y: (rect.minY - b.minY) / b.height,
                      width: rect.width / b.width, height: rect.height / b.height)
    }

    /// `unit` (from `unitRect`) placed on a page with `bounds`.
    package static func rect(unit: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + unit.minX * bounds.width, y: bounds.minY + unit.minY * bounds.height,
               width: unit.width * bounds.width, height: unit.height * bounds.height)
    }

    /// The scale to render `rect` at (pixels per point): as sharp as `maxScale`, but the long edge at
    /// most `maxLongEdge` pixels (`AssistImage.maxLongEdge`) and never below 1 unless the box itself
    /// is larger than the cap.
    package static func renderScale(for rect: CGRect, maxLongEdge: CGFloat = AssistImage.maxLongEdge,
                                    maxScale: CGFloat = 3) -> CGFloat {
        let long = max(rect.width, rect.height)
        guard long > 0 else { return 1 }
        return min(maxScale, maxLongEdge / long)
    }

    /// Whole pixels for `rect` at `scale`, each side at least 1 and the long edge within the cap.
    package static func pixelSize(for rect: CGRect, scale: CGFloat,
                                  maxLongEdge: CGFloat = AssistImage.maxLongEdge) -> CGSize {
        let w = max(1, min(maxLongEdge, (rect.width * scale).rounded()))
        let h = max(1, min(maxLongEdge, (rect.height * scale).rounded()))
        return CGSize(width: w, height: h)
    }

    /// Trimmed, non-empty, at most `maxText` characters.
    package static func trimmed(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(maxText))
    }
}

/// Where a floating mini-toolbar sits over the page view (the selection's Copy / Ask / Explain bar, the
/// box's bar): centred over its target, above it when there is room, else below, else inside its top;
/// always within the viewport's margins. Coordinates have their origin top-left (SwiftUI's). Pure;
/// owned by Slice C (reader).
package enum ReaderOverlayPlacement {
    /// The toolbar's centre, or nil when the target is entirely outside the viewport (scrolled away:
    /// the toolbar hides).
    package static func toolbarCenter(target: CGRect, toolbar: CGSize, viewport: CGSize, gap: CGFloat = 8,
                                      margin: CGFloat = 8) -> CGPoint? {
        let view = CGRect(origin: .zero, size: viewport)
        guard !target.isNull, target.intersects(view) || view.contains(target.origin) else { return nil }
        let half = toolbar.width / 2
        let minX = margin + half, maxX = viewport.width - margin - half
        let x = minX <= maxX ? min(max(target.midX, minX), maxX) : viewport.width / 2
        let above = target.minY - gap - toolbar.height
        let below = target.maxY + gap
        let y: CGFloat
        if above >= margin {
            y = above + toolbar.height / 2
        } else if below + toolbar.height <= viewport.height - margin {
            y = below + toolbar.height / 2
        } else {
            // A target taller than the view: pin to the top of what is visible of it.
            y = max(target.minY, 0) + margin + toolbar.height / 2
        }
        return CGPoint(x: x, y: min(y, viewport.height - margin - toolbar.height / 2))
    }
}
