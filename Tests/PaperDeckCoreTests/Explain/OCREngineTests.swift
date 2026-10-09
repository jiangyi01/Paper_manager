import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// Vision OCR end to end on synthetic images drawn in memory with CoreText (never a screenshot,
/// no permission involved): English prose, Chinese, a text-free chart, a blank capture. One image
/// at a time (serialized), small images only.
@Suite(.serialized) struct OCREngineTests {
    @Test func readsEnglishProseInReadingOrderAndCallsItText() async throws {
        let image = try #require(ExplainKit.render(
            ["We regularize the attention weights by penalizing",
             "their entropy across heads, which keeps each head",
             "focused on a small set of tokens."], width: 900, height: 200))
        let r = try await OCREngine.recognize(image, languages: OCREngine.defaultLanguages, customWords: ["regularize"])
        let flat = r.text.lowercased()
        #expect(flat.contains("regularize the attention weights"), "\(r.text)")
        #expect(flat.contains("entropy") && flat.contains("tokens"))
        let first = try #require(flat.range(of: "regularize")), last = try #require(flat.range(of: "tokens"))
        #expect(first.lowerBound < last.lowerBound)
        #expect(r.meanConfidence > 0.5 && !r.lines.isEmpty && !r.paragraphs.isEmpty)
        // Boxes are in the image's pixels, top-left origin: the first line sits near the top.
        let top = try #require(r.lines.first?.box)
        #expect(top.minY < 80 && top.maxX <= 900 && top.minX >= 0)
        #expect(RegionClassifier.classify(r, imageSize: CGSize(width: 900, height: 200)) == .text)
        // The lens: the block under a point on the second line is the paragraph holding it.
        let block = OCRPostProcess.block(at: CGPoint(x: 200, y: 80), in: r)
        #expect(block?.text.lowercased().contains("entropy") == true)
    }

    @Test func readsSimplifiedChineseWithoutSpaces() async throws {
        let image = try #require(ExplainKit.render(["注意力机制让模型关注重要的词", "这一方法不需要额外的参数"], width: 900, height: 160,
                                                    fontSize: 36, font: "PingFang SC"))
        let r = try await OCREngine.recognize(image, languages: OCREngine.defaultLanguages, customWords: [])
        #expect(r.text.contains("注意力") && r.text.contains("参数"), "\(r.text) \(r.lines)")
        #expect(!r.text.contains("注意 力"))
    }

    @Test func aChartWithoutTextAndABlankCaptureAreVisual() async throws {
        let chart = try #require(ExplainKit.bars())
        let c = try await OCREngine.recognize(chart, languages: OCREngine.defaultLanguages, customWords: [])
        #expect(RegionClassifier.classify(c, imageSize: CGSize(width: chart.width, height: chart.height)) == .visual)
        let blank = try #require(ExplainKit.flat(width: 300, height: 200, gray: 1))
        let b = try await OCREngine.recognize(blank, languages: ["en-US"], customWords: [])
        #expect(b.isEmpty && RegionClassifier.classify(b, imageSize: CGSize(width: 300, height: 200)) == .visual)
        // Too small to read at all.
        let dot = try #require(ExplainKit.flat(width: 3, height: 3))
        #expect(try await OCREngine.recognize(dot, languages: [], customWords: []) == .empty)
    }
}
