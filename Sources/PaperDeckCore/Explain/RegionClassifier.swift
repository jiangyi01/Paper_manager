import CoreGraphics
import Foundation

/// What a capture is, for what goes to the model (LN §4.6, dive-capture §4): `text` sends the
/// OCR text only (cheaper, faster, works on-device); `mixed` sends the image with the OCR as a hint
/// ("may be garbled — trust the image": formulas, tables, low confidence, a figure with a caption);
/// `visual` sends the image only (a chart, a photo, too little legible text). The panel's
/// "Send as image" toggle overrides it per turn.
package enum RegionKind: String, Sendable, Equatable, CaseIterable {
    case text, mixed, visual
}

/// The measurements the decision uses (exposed for tests and tuning).
package struct RegionMetrics: Sendable, Equatable {
    /// Σ line-box area / image area (0…1).
    package var coverage: Double
    package var meanConfidence: Double
    /// Non-whitespace characters.
    package var characters: Int
    package var lines: Int
    /// Share of characters that are math: operators, Greek, mathematical alphanumerics.
    package var mathRatio: Double
    /// Share of tokens of ≤ 2 characters (non-CJK): symbols, indices, axis ticks.
    package var shortTokenRatio: Double
    /// Share of tokens that are numbers ("91.2", "3", "95%"): a table of results.
    package var numericTokenRatio: Double
    /// Share of lines whose height is more than `jitterTolerance` off the median: sub / superscripts,
    /// stacked fractions, mixed font sizes.
    package var heightJitter: Double
    /// Share of CJK characters (CJK prose has no short tokens; reported, not decided on).
    package var cjkShare: Double
}

package enum RegionClassifier {
    /// The decision's thresholds (tuned on the synthetic fixtures in `Fixtures/explain/`; the
    /// confidence ones calibrated to RecognizeDocumentsRequest's scale, see `OCREngine`).
    package struct Thresholds: Sendable, Equatable {
        /// Below this many characters there is too little text: visual.
        package var minCharacters = 12
        /// Below this coverage the text is incidental (axis labels on a chart): visual.
        package var minCoverage = 0.04
        /// Below this mean confidence the OCR is unusable (the wrong script): visual.
        package var minConfidence = 0.25
        /// Below this mean confidence the OCR is shaky (a formula read as text): mixed.
        package var lowConfidence = 0.45
        /// Above these: mixed (math / symbols / sub- and superscripts).
        package var mathRatio = 0.12
        package var shortTokenRatio = 0.45
        package var numericTokenRatio = 0.35
        package var heightJitter = 0.40
        /// A line counts as jittery when its height is this far (fraction) off the median.
        package var jitterTolerance = 0.35
        /// Sparse text (a caption under a figure, chart labels): coverage below this with at most
        /// `sparseMaxLines` lines → mixed.
        package var sparseCoverage = 0.18
        package var sparseMaxLines = 4

        package init() {}
        package static let `default` = Thresholds()
    }

    /// The contract: `.default` thresholds.
    package static func classify(_ ocr: OCRResult, imageSize: CGSize) -> RegionKind {
        classify(ocr, imageSize: imageSize, thresholds: .default)
    }

    package static func classify(_ ocr: OCRResult, imageSize: CGSize, thresholds t: Thresholds) -> RegionKind {
        decide(metrics(ocr, imageSize: imageSize, thresholds: t), thresholds: t)
    }

    /// The decision table (in this order):
    /// 1. characters < minCharacters, coverage < minCoverage or confidence < minConfidence → visual
    /// 2. confidence < lowConfidence, mathRatio > …, shortTokenRatio > …, numericTokenRatio > … or
    ///    heightJitter > … → mixed
    /// 3. coverage < sparseCoverage with ≤ sparseMaxLines lines → mixed
    /// 4. otherwise → text
    package static func decide(_ m: RegionMetrics, thresholds t: Thresholds = .default) -> RegionKind {
        if m.characters < t.minCharacters || m.coverage < t.minCoverage || m.meanConfidence < t.minConfidence {
            return .visual
        }
        if m.meanConfidence < t.lowConfidence || m.mathRatio > t.mathRatio || m.shortTokenRatio > t.shortTokenRatio
            || m.numericTokenRatio > t.numericTokenRatio || m.heightJitter > t.heightJitter {
            return .mixed
        }
        if m.coverage < t.sparseCoverage && m.lines <= t.sparseMaxLines { return .mixed }
        return .text
    }

    package static func metrics(_ ocr: OCRResult, imageSize: CGSize, thresholds t: Thresholds = .default) -> RegionMetrics {
        let area = Double(max(imageSize.width, 1) * max(imageSize.height, 1))
        let bounds = CGRect(origin: .zero, size: imageSize)
        let covered = ocr.lines.reduce(0.0) { sum, l in
            let r = l.box.intersection(bounds)
            return sum + (r.isNull ? 0 : Double(r.width * r.height))
        }
        let text = ocr.lines.map(\.text).joined(separator: " ")
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        let math = scalars.filter(isMath).count
        let cjk = text.filter(OCRPostProcess.isCJK).count
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let short = tokens.filter { $0.count <= 2 && !$0.contains(where: OCRPostProcess.isCJK) }.count
        let numeric = tokens.filter { $0.range(of: #"^[±+−-]?\d+([.,]\d+)?%?$"#, options: .regularExpression) != nil }.count
        let heights = ocr.lines.map(\.box.height).filter { $0 > 0 }
        let median = OCRPostProcess.median(heights)
        let jittery = heights.filter { median > 0 && abs($0 - median) > t.jitterTolerance * median }.count
        let characters = scalars.count
        return RegionMetrics(
            coverage: min(covered / area, 1),
            meanConfidence: ocr.meanConfidence,
            characters: characters,
            lines: ocr.lines.count,
            mathRatio: characters == 0 ? 0 : Double(math) / Double(characters),
            shortTokenRatio: tokens.isEmpty ? 0 : Double(short) / Double(tokens.count),
            numericTokenRatio: tokens.isEmpty ? 0 : Double(numeric) / Double(tokens.count),
            heightJitter: heights.isEmpty ? 0 : Double(jittery) / Double(heights.count),
            cjkShare: text.isEmpty ? 0 : Double(cjk) / Double(max(text.filter { !$0.isWhitespace }.count, 1)))
    }

    /// Operators and relations, Greek letters, mathematical alphanumerics, sub- / superscript digits.
    package static func isMath(_ u: Unicode.Scalar) -> Bool {
        if mathSymbols.contains(u) { return true }
        switch u.value {
        case 0x0391...0x03C9, 0x03D0...0x03F5,          // Greek
             0x1D400...0x1D7FF,                          // mathematical alphanumerics
             0x2070...0x209F,                            // super- / subscripts
             0x2100...0x214F,                            // letterlike (ℝ, ℓ, ℏ)
             0x2200...0x22FF, 0x27C0...0x27EF, 0x2980...0x2AFF,   // operators
             0x2190...0x21FF:                            // arrows
            return true
        default:
            return false
        }
    }

    private static let mathSymbols: Set<Unicode.Scalar> = Set("=+−×·÷±≤≥≈≠∝∞∑∏∫∂∇√∈∉⊂⊆∪∩∀∃→⇒⇔^_|‖{}\\<>~′″¹²³".unicodeScalars)
}
