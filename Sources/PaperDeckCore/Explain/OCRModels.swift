import CoreGraphics
import Foundation

// What on-device OCR (`OCREngine`, Vision) saw in a capture, after `OCRPostProcess` put it into
// reading order. Boxes are in the captured image's pixels with a top-left origin (y down), the
// space `ExplainFocus.pixel(in:)` maps a click into. Untrusted text: it goes to a model only
// inside a neutralized block (`ExplainPrompt`), and is never logged.

/// One recognized word (RecognizeDocumentsRequest gives them; the fallback request doesn't).
package struct OCRWord: Sendable, Equatable {
    package var text: String
    package var box: CGRect

    package init(text: String, box: CGRect) { self.text = text; self.box = box }
}

/// One visual line.
package struct OCRLine: Sendable, Equatable {
    package var text: String
    package var box: CGRect
    /// 0…1 (Vision's top candidate).
    package var confidence: Double
    /// Empty when the engine gave none (`OCRPostProcess.word(at:)` then splits the line evenly).
    package var words: [OCRWord]

    package init(text: String, box: CGRect, confidence: Double, words: [OCRWord] = []) {
        self.text = text; self.box = box; self.confidence = confidence; self.words = words
    }
}

/// One paragraph in reading order.
package struct OCRParagraph: Sendable, Equatable {
    /// The lines joined (`OCRPostProcess.join`: de-hyphenated, CJK without spaces).
    package var text: String
    package var box: CGRect
    /// Indices into `OCRResult.lines`, in reading order.
    package var lineIndices: [Int]
    /// The column (0 = leftmost) the paragraph sits in; -1 when it spans columns.
    package var column: Int

    package init(text: String, box: CGRect, lineIndices: [Int], column: Int = 0) {
        self.text = text; self.box = box; self.lineIndices = lineIndices; self.column = column
    }
}

/// A capture's OCR in reading order.
package struct OCRResult: Sendable, Equatable {
    /// Visual lines in reading order (paragraph by paragraph).
    package var lines: [OCRLine]
    package var paragraphs: [OCRParagraph]
    /// The paragraphs' text, separated by blank lines.
    package var text: String
    /// 0…1, the lines' mean confidence (0 without lines).
    package var meanConfidence: Double

    package init(lines: [OCRLine], paragraphs: [OCRParagraph], text: String, meanConfidence: Double) {
        self.lines = lines; self.paragraphs = paragraphs; self.text = text; self.meanConfidence = meanConfidence
    }

    package static let empty = OCRResult(lines: [], paragraphs: [], text: "", meanConfidence: 0)

    /// No text at all.
    package var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The median line height in pixels (0 without lines).
    package var medianLineHeight: CGFloat {
        let hs = lines.map(\.box.height).filter { $0 > 0 }.sorted()
        return hs.isEmpty ? 0 : hs[hs.count / 2]
    }
}
