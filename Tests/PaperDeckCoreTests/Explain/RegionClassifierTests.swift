import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// The text / mixed / visual decision (LN §4.6) on every synthetic fixture, the metrics behind it,
/// and that each threshold is load-bearing (moving it flips the fixture it guards).
@Suite struct RegionClassifierTests {
    @Test(arguments: ExplainKit.fixtureNames)
    func eachFixtureGetsItsExpectedKind(_ name: String) throws {
        let f = try ExplainKit.fixture(name)
        let kind = RegionClassifier.classify(f.result, imageSize: f.imageSize)
        let m = RegionClassifier.metrics(f.result, imageSize: f.imageSize)
        #expect(kind == f.expect, "\(name) (\(f.note)): \(m)")
    }

    @Test func metricsMeasureWhatTheySay() throws {
        let prose = try ExplainKit.fixture("prose")
        let m = RegionClassifier.metrics(prose.result, imageSize: prose.imageSize)
        #expect(m.coverage > 0.4 && m.coverage < 0.6)
        #expect(m.mathRatio == 0 && m.heightJitter == 0 && m.numericTokenRatio == 0)
        #expect(m.shortTokenRatio > 0.15 && m.shortTokenRatio < 0.35)          // English prose
        #expect(m.lines == 8 && m.meanConfidence > 0.6)
        let eq = try ExplainKit.fixture("equation")
        let e = RegionClassifier.metrics(eq.result, imageSize: eq.imageSize)
        #expect(e.mathRatio > 0.2 && e.heightJitter > 0.3)
        let table = try ExplainKit.fixture("table")
        #expect(RegionClassifier.metrics(table.result, imageSize: table.imageSize).numericTokenRatio > 0.5)
        let zh = try ExplainKit.fixture("chinese")
        let z = RegionClassifier.metrics(zh.result, imageSize: zh.imageSize)
        #expect(z.cjkShare > 0.9 && z.shortTokenRatio == 0)
        let empty = RegionClassifier.metrics(.empty, imageSize: .zero)
        #expect(empty.characters == 0 && empty.coverage == 0)
        #expect(RegionClassifier.isMath("∑") && RegionClassifier.isMath("α") && RegionClassifier.isMath("ℝ")
                && RegionClassifier.isMath("²") && !RegionClassifier.isMath("a") && !RegionClassifier.isMath("-"))
    }

    /// Every threshold guards a fixture: nudging it past the fixture's measurement flips the kind.
    @Test func everyThresholdIsLoadBearing() throws {
        func kind(_ name: String, _ t: RegionClassifier.Thresholds) throws -> RegionKind {
            let f = try ExplainKit.fixture(name)
            return RegionClassifier.classify(f.result, imageSize: f.imageSize, thresholds: t)
        }
        var t = RegionClassifier.Thresholds()
        t.minCoverage = 0.001
        #expect(try kind("chart", t) != .visual)                         // chart labels pass as text-ish
        t = .init(); t.minConfidence = 0.1
        #expect(try kind("unreadable", t) == .mixed)
        t = .init(); t.lowConfidence = 0.3
        #expect(try kind("low_confidence", t) == .text)
        t = .init(); t.mathRatio = 0.9; t.shortTokenRatio = 0.9
        #expect(try kind("inline_math_dense", t) == .text)
        t = .init(); t.numericTokenRatio = 0.9; t.shortTokenRatio = 0.9; t.mathRatio = 0.9
        #expect(try kind("table", t) == .text)
        t = .init(); t.heightJitter = 0.9; t.mathRatio = 0.9; t.shortTokenRatio = 0.9; t.lowConfidence = 0.3
        #expect(try kind("equation", t) == .text)
        t = .init(); t.sparseCoverage = 0.01
        #expect(try kind("figure_caption", t) == .text)
        t = .init(); t.minCharacters = 10_000
        #expect(try kind("prose", t) == .visual)
        t = .init(); t.shortTokenRatio = 0.1
        #expect(try kind("prose", t) == .mixed)                          // prose has ~25 % short words
    }

    @Test func theDecisionTableOrder() {
        func m(coverage: Double = 0.5, confidence: Double = 0.95, chars: Int = 200, lines: Int = 8, math: Double = 0,
               short: Double = 0.2, numeric: Double = 0, jitter: Double = 0) -> RegionMetrics {
            RegionMetrics(coverage: coverage, meanConfidence: confidence, characters: chars, lines: lines, mathRatio: math,
                          shortTokenRatio: short, numericTokenRatio: numeric, heightJitter: jitter, cjkShare: 0)
        }
        #expect(RegionClassifier.decide(m()) == .text)
        #expect(RegionClassifier.decide(m(chars: 11)) == .visual)
        #expect(RegionClassifier.decide(m(coverage: 0.03)) == .visual)
        #expect(RegionClassifier.decide(m(confidence: 0.24)) == .visual)
        #expect(RegionClassifier.decide(m(confidence: 0.40)) == .mixed)
        #expect(RegionClassifier.decide(m(confidence: 0.55)) == .text)          // clean English on the document scale
        #expect(RegionClassifier.decide(m(math: 0.13)) == .mixed)
        #expect(RegionClassifier.decide(m(short: 0.46)) == .mixed)
        #expect(RegionClassifier.decide(m(numeric: 0.36)) == .mixed)
        #expect(RegionClassifier.decide(m(jitter: 0.41)) == .mixed)
        #expect(RegionClassifier.decide(m(coverage: 0.1, lines: 4)) == .mixed)
        #expect(RegionClassifier.decide(m(coverage: 0.1, lines: 5)) == .text)
        // Visual wins over mixed (too little text to hint with).
        #expect(RegionClassifier.decide(m(coverage: 0.01, math: 0.5)) == .visual)
    }
}
