import CoreGraphics
import Foundation
import Vision

/// On-device OCR of a capture (Vision; no network, no quota, no permission). macOS 26's
/// `RecognizeDocumentsRequest` gives paragraphs in reading order (and words); when it can't read
/// every requested language, fails or finds nothing, `RecognizeTextRequest` (accurate, language
/// correction) runs instead and `OCRPostProcess.assemble` builds the layout.
///
/// Languages are candidates with automatic detection on: measured on synthetic CoreText images
/// (2026-10-02), a fixed `en-US, zh-Hans` order reads no Chinese at all (the first language's
/// model runs), `zh-Hans` first glues English lines, and detection picks the right model for both.
/// Line confidences differ by request: the document request's are graded (clean English ≈ 0.55–0.65,
/// Chinese ≈ 0.85–0.92, a garbled formula ≈ 0.35, the wrong model ≈ 0.2–0.3); the text request
/// reports only 1.0 / 0.5 (no signal). `RegionClassifier.Thresholds` is calibrated to the former.
/// `customWords`: the located paper's own vocabulary (title words, key terms), so its names and
/// coined words survive correction. Async and off the main actor; one capture at a time is the
/// caller's rule. Never logs the text.
package enum OCREngine {
    package static let defaultLanguages = ["en-US", "zh-Hans"]
    /// Vision's limit is generous; more words only slow correction down.
    package static let maxCustomWords = 100

    package static func recognize(_ image: CGImage, languages: [String], customWords: [String]) async throws -> OCRResult {
        let size = CGSize(width: image.width, height: image.height)
        guard image.width >= 4, image.height >= 4 else { return .empty }
        let langs = (languages.isEmpty ? defaultLanguages : languages).map { Locale.Language(identifier: $0) }
        let words = Array(customWords.filter { !$0.isEmpty }.prefix(maxCustomWords))
        if let doc = try? await documentOCR(image, size: size, languages: langs, customWords: words), !doc.isEmpty {
            return doc
        }
        return try await textOCR(image, size: size, languages: langs, customWords: words)
    }

    /// RecognizeDocumentsRequest, or nil when it can't read every requested language.
    private static func documentOCR(_ image: CGImage, size: CGSize, languages: [Locale.Language],
                                    customWords: [String]) async throws -> OCRResult? {
        var request = RecognizeDocumentsRequest()
        let supported = request.supportedRecognitionLanguages
        guard languages.allSatisfy({ l in supported.contains { same($0, l) } }) else { return nil }
        request.textRecognitionOptions.recognitionLanguages = languages
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.customWords = customWords
        request.barcodeDetectionOptions.enabled = false
        let observations = try await request.perform(on: image)
        var paragraphs: [[OCRLine]] = []
        for observation in observations {
            for paragraph in observation.document.paragraphs {
                let words = (paragraph.words ?? []).compactMap { w -> OCRWord? in
                    guard let c = w.topCandidates(1).first else { return nil }
                    return OCRWord(text: c.string, box: w.boundingBox.toImageCoordinates(size, origin: .upperLeft))
                }
                let lines = paragraph.lines.compactMap { o -> OCRLine? in
                    guard let c = o.topCandidates(1).first else { return nil }
                    let box = o.boundingBox.toImageCoordinates(size, origin: .upperLeft)
                    let inLine = words.filter { box.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
                    return OCRLine(text: c.string, box: box, confidence: Double(c.confidence), words: inLine)
                }
                if !lines.isEmpty { paragraphs.append(lines) }
            }
        }
        return OCRPostProcess.assemble(paragraphs: paragraphs)
    }

    private static func textOCR(_ image: CGImage, size: CGSize, languages: [Locale.Language],
                                customWords: [String]) async throws -> OCRResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = request.supportedRecognitionLanguages
        let usable = languages.filter { l in supported.contains { same($0, l) } }
        request.recognitionLanguages = usable.isEmpty ? [Locale.Language(identifier: "en-US")] : usable
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.customWords = customWords
        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { o -> OCRLine? in
            guard let c = o.topCandidates(1).first else { return nil }
            return OCRLine(text: c.string, box: o.boundingBox.toImageCoordinates(size, origin: .upperLeft),
                           confidence: Double(c.confidence))
        }
        return OCRPostProcess.assemble(lines, imageSize: size)
    }

    /// "zh-Hans" and "zh-Hans-CN" (or "en-US" / "en-Latn-US") are the same recognition language.
    private static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode && (a.script == nil || b.script == nil || a.script == b.script)
            && (a.region == nil || b.region == nil || a.region == b.region)
    }
}
