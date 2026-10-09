import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PaperDeckCore

/// The turn's image (dive-cli §7): ≤ 1568 px long edge and ≤ 1.15 MP, never upscaled (a small
/// formula keeps its native pixels), PNG unless over 1.5 MB (then JPEG q 0.85, smaller until it
/// fits); a flat capture (protected content) is recognized.
@Suite struct ExplainImageTests {
    @Test func targetSizesRespectBothLimitsAndNeverUpscale() {
        #expect(ExplainImage.targetSize(for: CGSize(width: 400, height: 120)) == CGSize(width: 400, height: 120))
        #expect(ExplainImage.targetSize(for: CGSize(width: 1000, height: 1000)) == CGSize(width: 1000, height: 1000))  // 1.0 MP
        let wide = ExplainImage.targetSize(for: CGSize(width: 3136, height: 400))      // long edge
        #expect(wide == CGSize(width: 1568, height: 200))
        let big = ExplainImage.targetSize(for: CGSize(width: 2880, height: 1800))       // both limits
        #expect(max(big.width, big.height) <= 1568 && big.width * big.height <= 1_150_000)
        #expect(abs(big.width / big.height - 1.6) < 0.01)
        let square = ExplainImage.targetSize(for: CGSize(width: 1500, height: 1500))    // area only
        #expect(square.width * square.height <= 1_150_000 && square.width == square.height)
        #expect(ExplainImage.targetSize(for: CGSize(width: 0.4, height: 0.4)) == CGSize(width: 1, height: 1))
    }

    @Test func aSmallFormulaKeepsItsNativePixelsAsPNG() throws {
        let formula = try #require(ExplainKit.render(["E = mc²"], width: 240, height: 64))
        let img = try #require(ExplainImage.prepare(formula))
        #expect(img.mediaType == "image/png" && img.pixelSize == CGSize(width: 240, height: 64) && img.isAcceptable)
        let decoded = try #require(CGImageSourceCreateWithData(img.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 240 && decoded.height == 64)
    }

    @Test func aRetinaScreenIsDownscaledWithinTheLimits() throws {
        let screen = try #require(ExplainKit.bars(width: 2880, height: 1800))
        let img = try #require(ExplainImage.prepare(screen))
        #expect(img.isAcceptable && img.data.count <= ExplainImage.maxBytes)
        #expect(img.pixelSize.width * img.pixelSize.height <= 1_150_000 && max(img.pixelSize.width, img.pixelSize.height) <= 1568)
    }

    @Test func anIncompressibleImageFallsBackToJPEGUnderTheByteCap() throws {
        let noisy = try #require(ExplainKit.noise(width: 1200, height: 900))
        #expect((ExplainImage.png(noisy)?.count ?? 0) > ExplainImage.maxBytes)          // why the fallback exists
        let img = try #require(ExplainImage.prepare(noisy))
        #expect(img.mediaType == "image/jpeg" && img.data.count <= ExplainImage.maxBytes && img.isAcceptable)
        #expect(img.data.starts(with: [0xFF, 0xD8]))
    }

    @Test func flatCapturesAreBlank() throws {
        let black = try #require(ExplainKit.flat(width: 200, height: 100, gray: 0))
        let white = try #require(ExplainKit.flat(width: 200, height: 100, gray: 1))
        let chart = try #require(ExplainKit.bars())
        #expect(ExplainImage.isBlank(black) && ExplainImage.isBlank(white) && !ExplainImage.isBlank(chart))
        let small = try #require(ExplainKit.flat(width: 50, height: 50, gray: 0))
        let l = try #require(ExplainImage.luminance(small))
        #expect(l.mean < 0.01 && l.deviation < 0.01)
    }
}
