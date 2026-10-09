import CoreGraphics
import Foundation

/// A click instead of a box (dive-capture §2, LN §4.4): in frame mode a drag smaller than
/// `CaptureGeometry.clickSide`, in the lens mode any click. The overlay crops the band around the
/// click (`CaptureGeometry.band`, clipped to the window under it) and marks the click here; reading
/// the capture (local OCR) then keeps only what is under it — the paragraph, or with ⇧ the term.
/// When no paragraph is under it, only `fallback` goes: the figure the overlay found around the click
/// in the still's pixels, or a small band (F3: never the whole band the user didn't see). The capture
/// may hold a larger area around the band (`band`, CUX-8): a paragraph that runs past the band's edge
/// is then read once more from it (`ExplainFocusResolver.read`). Phase-3 integration (Lead); the
/// fallback and the noise filter by fix-capture-ux; the wider read by capture-polish.
package struct ExplainFocus: Sendable, Equatable {
    /// The click as a fraction of the capture image (0…1 each way, top-left origin, y down), so it
    /// survives the image being scaled down for sending. The capture image is the one OCR reads
    /// (`ExplainCapture.ocrImage`, else `image`).
    package var unit: CGPoint
    /// The term under the click (⇧-click in the lens), not its paragraph.
    package var term: Bool
    /// What is sent when no paragraph is under the click (a fraction of the capture image, like
    /// `unit`): the figure around the click, else a small band. nil: the old behaviour (tests).
    package var fallback: CGRect?
    /// The band around the click, read first (a fraction of the capture image, like `unit`) when the
    /// capture holds a larger area — the window under the click around it (CUX-8). nil: the whole
    /// capture is the band.
    package var band: CGRect?

    package init(unit: CGPoint, term: Bool = false, fallback: CGRect? = nil, band: CGRect? = nil) {
        self.unit = CGPoint(x: min(max(unit.x, 0), 1), y: min(max(unit.y, 0), 1)); self.term = term
        self.fallback = fallback.flatMap(Self.clampUnit)
        self.band = band.flatMap(Self.clampUnit).flatMap { $0 == CGRect(x: 0, y: 0, width: 1, height: 1) ? nil : $0 }
    }

    /// The click at `local` (points) inside `rect` (points, the band), as a fraction of the band;
    /// `fallback` (points, same space) likewise.
    package init?(local: CGPoint, in rect: CGRect, term: Bool = false, fallback: CGRect? = nil) {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let unitFallback = fallback.map {
            CGRect(x: ($0.minX - rect.minX) / rect.width, y: ($0.minY - rect.minY) / rect.height,
                   width: $0.width / rect.width, height: $0.height / rect.height)
        }
        self.init(unit: CGPoint(x: (local.x - rect.minX) / rect.width, y: (local.y - rect.minY) / rect.height), term: term,
                  fallback: unitFallback)
    }

    /// The click in an image of `size` pixels.
    package func pixel(in size: CGSize) -> CGPoint { CGPoint(x: unit.x * size.width, y: unit.y * size.height) }

    /// The fallback in an image of `size` pixels, snapped outward to whole pixels inside it (nil
    /// without one, or when it is empty).
    package func fallbackPixels(in size: CGSize) -> CGRect? { fallback.flatMap { Self.pixels($0, in: size) } }

    /// The band in an image of `size` pixels, snapped outward to whole pixels inside it (nil without
    /// one: the whole image is read).
    package func bandPixels(in size: CGSize) -> CGRect? { band.flatMap { Self.pixels($0, in: size) } }

    /// This focus — made for a capture of `band` (display-local points) — for a capture of the larger
    /// `area` that holds it: the click and the fallback as fractions of `area`, and `band` marked
    /// inside it (read first). Unchanged when `area` is `band` or doesn't hold it.
    package func widened(from band: CGRect, to area: CGRect) -> ExplainFocus {
        let b = band.standardized, a = area.standardized
        guard b.width > 0, b.height > 0, a.width > 0, a.height > 0, a != b,
              a.insetBy(dx: -0.5, dy: -0.5).contains(b) else { return self }
        func inArea(_ u: CGRect) -> CGRect {
            CGRect(x: (b.minX + u.minX * b.width - a.minX) / a.width, y: (b.minY + u.minY * b.height - a.minY) / a.height,
                   width: u.width * b.width / a.width, height: u.height * b.height / a.height)
        }
        let click = CGPoint(x: (b.minX + unit.x * b.width - a.minX) / a.width, y: (b.minY + unit.y * b.height - a.minY) / a.height)
        return ExplainFocus(unit: click, term: term, fallback: fallback.map(inArea),
                            band: inArea(CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    private static func pixels(_ u: CGRect, in size: CGSize) -> CGRect? {
        let bounds = CGRect(origin: .zero, size: size)
        let raw = CGRect(x: u.minX * size.width, y: u.minY * size.height, width: u.width * size.width, height: u.height * size.height)
        let snapped = CaptureGeometry.snap(raw, within: bounds)
        return snapped.width >= 1 && snapped.height >= 1 ? snapped : nil
    }

    private static func clampUnit(_ r: CGRect) -> CGRect? {
        let s = r.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return s.isNull || s.width <= 0 || s.height <= 0 ? nil : s
    }
}

/// What a click's band holds under the click, from the band's OCR. Pure and tested.
package enum ExplainFocusResolver {
    package struct Result: Sendable, Equatable {
        /// The text explained: the paragraph, or the term (nil: the click is on no text — a figure).
        package var selection: String?
        /// The paragraph around the click (locating the paper and its context use it).
        package var paragraph: String?
        /// The part of the band image kept (pixels): the paragraph's box padded, or the focus'
        /// fallback (the figure / small band) when nothing readable is under the click.
        package var crop: CGRect?
        /// The paragraph's own OCR, in `crop`'s pixels (the region classifier reads it).
        package var block: OCRResult?

        package init(selection: String?, paragraph: String?, crop: CGRect?, block: OCRResult?) {
            self.selection = selection; self.paragraph = paragraph; self.crop = crop; self.block = block
        }

        /// Nothing under the click and no fallback (a focus made without one): the image is kept as it is.
        package static let none = Result(selection: nil, paragraph: nil, crop: nil, block: nil)
    }

    /// The paragraph's box grows by this many median line heights on each side (descenders,
    /// accents and a formula's sub- and superscripts stay in the image).
    package static let padding: CGFloat = 0.6
    /// A block counts as a paragraph to explain only with this many characters (CUX-4: a panel
    /// letter, an axis tick or a legend entry next to the click is part of a figure, not text) …
    package static let minCharacters = RegionClassifier.Thresholds.default.minCharacters
    /// … and this mean line confidence (the classifier's "unusable OCR" bound).
    package static let minConfidence = RegionClassifier.Thresholds.default.minConfidence
    /// A ⇧-click's term may come from a short block it is on (a label naming a term), with this many characters.
    package static let minTermCharacters = 2

    package static func resolve(_ ocr: OCRResult, imageSize: CGSize, focus: ExplainFocus) -> Result {
        let point = focus.pixel(in: imageSize)
        guard let block = block(at: point, in: ocr, term: focus.term) else { return unresolved(focus, imageSize: imageSize) }
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return unresolved(focus, imageSize: imageSize) }
        let h = max(ocr.medianLineHeight, 1)
        let bounds = CGRect(origin: .zero, size: imageSize)
        let padded = block.box.insetBy(dx: -padding * h, dy: -padding * h).intersection(bounds)
        let crop = padded.isNull || padded.isEmpty ? nil : CaptureGeometry.snap(padded, within: bounds)
        let origin = crop?.origin ?? .zero
        let lines = block.lineIndices.compactMap { ocr.lines.indices.contains($0) ? ocr.lines[$0] : nil }.map { line in
            var l = line
            l.box = line.box.offsetBy(dx: -origin.x, dy: -origin.y)
            l.words = line.words.map { OCRWord(text: $0.text, box: $0.box.offsetBy(dx: -origin.x, dy: -origin.y)) }
            return l
        }
        let paragraph = OCRParagraph(text: text, box: block.box.offsetBy(dx: -origin.x, dy: -origin.y),
                                     lineIndices: Array(lines.indices), column: block.column)
        let mean = lines.isEmpty ? ocr.meanConfidence : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
        let own = OCRResult(lines: lines, paragraphs: [paragraph], text: text, meanConfidence: mean)
        let selection = focus.term ? (OCRPostProcess.word(at: point, in: ocr) ?? text) : text
        return Result(selection: selection, paragraph: text, crop: crop, block: own)
    }

    /// Nothing readable under the click (or the OCR failed): only the focus' fallback — the figure
    /// around the click or a small band — is kept as the image; `.none` without a fallback.
    package static func unresolved(_ focus: ExplainFocus, imageSize: CGSize) -> Result {
        guard let crop = focus.fallbackPixels(in: imageSize) else { return .none }
        return Result(selection: nil, paragraph: nil, crop: crop, block: nil)
    }

    /// A click's capture read on this Mac (CUX-8): the band first (`focus.band`, else the whole
    /// image). When the paragraph under the click runs past a band edge beyond which the capture goes
    /// on (`OCRPostProcess.isCutOff`, within about a line of the edge: the next line may be cut away),
    /// the whole capture is read once more and its paragraph used — the capture never reaches past
    /// the window under the click. `ocr` reads a part of the image (pixels) and answers in that
    /// part's own pixels (nil: it failed). The result is in the whole image's pixels, like `resolve`.
    package static func read(_ focus: ExplainFocus, imageSize: CGSize,
                             ocr: @Sendable (CGRect) async -> OCRResult?) async -> Result {
        let whole = CGRect(origin: .zero, size: imageSize)
        let band = focus.bandPixels(in: imageSize) ?? whole
        guard let first = await ocr(band) else { return unresolved(focus, imageSize: imageSize) }
        let hit = resolve(OCRPostProcess.offset(first, by: band.origin), imageSize: imageSize, focus: focus)
        guard band != whole, hit.paragraph != nil, runsPast(band, in: imageSize, ocr: first, focus: focus),
              let second = await ocr(whole) else { return hit }
        let wider = resolve(second, imageSize: imageSize, focus: focus)
        return wider.paragraph != nil ? wider : hit
    }

    /// The paragraph under the click, in the band's own reading (`ocr`, band pixels), reaches an edge
    /// of `band` (pixels of an image of `size`) that the image goes on past.
    static func runsPast(_ band: CGRect, in size: CGSize, ocr: OCRResult, focus: ExplainFocus) -> Bool {
        let click = focus.pixel(in: size)
        guard let p = block(at: CGPoint(x: click.x - band.minX, y: click.y - band.minY), in: ocr, term: focus.term) else { return false }
        var open: OCRPostProcess.Edges = []
        if band.minX > 0.5 { open.insert(.left) }
        if band.minY > 0.5 { open.insert(.top) }
        if band.maxX < size.width - 0.5 { open.insert(.right) }
        if band.maxY < size.height - 0.5 { open.insert(.bottom) }
        return OCRPostProcess.isCutOff(p, imageSize: band.size, margin: max(2, ocr.medianLineHeight), edges: open)
    }

    /// The paragraph a click at `point` explains (CUX-4): a block that is real text (enough
    /// characters, readable confidence) containing the point first, else the nearest one within 1.5
    /// line heights. A click on a short block (a panel letter, a tick, a legend entry) is a click on
    /// its figure: nil — unless it is a ⇧-click on a label, whose term is wanted.
    package static func block(at point: CGPoint, in ocr: OCRResult, term: Bool) -> OCRParagraph? {
        guard !ocr.paragraphs.isEmpty else { return nil }
        let text = ocr.paragraphs.filter { isText($0, in: ocr) }
        if let hit = text.first(where: { $0.box.contains(point) }) { return hit }
        if let small = ocr.paragraphs.first(where: { $0.box.contains(point) }) {
            return term && characters(small) >= minTermCharacters && confidence(small, in: ocr) >= minConfidence ? small : nil
        }
        let h = max(ocr.medianLineHeight, 1)
        let near = text.map { ($0, distance($0.box, point)) }.min { $0.1 < $1.1 }
        guard let near, near.1 <= 1.5 * h else { return nil }
        return near.0
    }

    /// Enough characters and a readable confidence to be explained as text.
    package static func isText(_ p: OCRParagraph, in ocr: OCRResult) -> Bool {
        characters(p) >= minCharacters && confidence(p, in: ocr) >= minConfidence
    }

    static func characters(_ p: OCRParagraph) -> Int { p.text.unicodeScalars.filter { !$0.properties.isWhitespace }.count }

    static func confidence(_ p: OCRParagraph, in ocr: OCRResult) -> Double {
        let lines = p.lineIndices.compactMap { ocr.lines.indices.contains($0) ? ocr.lines[$0] : nil }
        return lines.isEmpty ? ocr.meanConfidence : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
