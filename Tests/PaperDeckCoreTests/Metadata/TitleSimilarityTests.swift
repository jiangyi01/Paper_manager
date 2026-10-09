import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct TitleSimilarityTests {
    private static let spatial = "SpatialFormer: universal spatial representation learning from subcellular molecular to multicellular landscapes"

    @Test func thresholdIsDesignValue() {
        #expect(TitleSimilarity.acceptThreshold == 0.92)
    }

    @Test func normalization() {
        #expect(TitleSimilarity.normalize("β-Catenin <i>in vivo</i>!") == "beta catenin in vivo")
        #expect(TitleSimilarity.normalize("  Naïve   CAFÉ—ﬁndings  ") == "naive cafe findings")
        #expect(TitleSimilarity.normalize("TNF-α & IL-1β") == "tnf alpha il 1 beta")
        #expect(TitleSimilarity.normalize("Ω-3 Σ") == "omega 3 sigma")
        #expect(TitleSimilarity.normalize("单细胞 图谱") == "单细胞 图谱")
        #expect(TitleSimilarity.normalize("?!…") == "")
    }

    @Test func equivalentTitlesScoreOne() {
        let pairs: [(String, String)] = [
            (Self.spatial, "SpatialFormer: Universal Spatial Representation Learning from Subcellular Molecular to Multicellular Landscapes"),
            ("Café-driven naïve Bayes", "Cafe driven naive bayes"),
            ("TGF-β signalling in α-cells", "TGF-beta signalling in alpha cells"),
            ("ﬁnding ﬂuorescent proteins", "finding fluorescent proteins"),
            ("<i>In vivo</i> CRISPR screens", "In vivo CRISPR screens."),
            ("单细胞图谱", "单细胞图谱"),
        ]
        for (a, b) in pairs {
            #expect(TitleSimilarity.score(a, b) == 1, "\(a) vs \(b)")
            #expect(TitleSimilarity.matches(a, b))
        }
    }

    @Test func pdfSpacingArtifactsStillMatch() {
        let split = "SpatialFormer: universal spatial repre sentation learning from subcellular molecular to multicellular landscapes"
        let glued = "SpatialFormer: universal spatial representation learning from subcellularmolecular to multicellular landscapes"
        let hyphenated = "SpatialFormer: universal spatial represen- tation learning from sub-cellular molecular to multi-cellular landscapes"
        #expect(TitleSimilarity.score(Self.spatial, split) >= 0.92)
        #expect(TitleSimilarity.score(Self.spatial, glued) >= 0.92)
        #expect(TitleSimilarity.score(glued, Self.spatial) >= 0.92)
        #expect(TitleSimilarity.score(Self.spatial, hyphenated) >= 0.92)
    }

    @Test func droppedLigaturesAndTyposStillMatch() {
        #expect(TitleSimilarity.matches("Deep learning classification of single cell transcriptomes",
                                        "Deep learning classication of single cell transcriptomes"))
        #expect(TitleSimilarity.matches(Self.spatial, Self.spatial.replacingOccurrences(of: "representation", with: "representaton")))
        #expect(TitleSimilarity.score("Genomic analysis", "Genomics analysis") < 1)
    }

    @Test func differentWorksAreRejected() {
        let journal = "Molecular and cellular dynamics of the developing human neocortex"
        let preprint = "Molecular and cellular dynamics of the developing human neocortex at single-cell resolution"
        #expect(TitleSimilarity.score(journal, preprint) < 0.92)
        #expect(!TitleSimilarity.matches(
            "Single-cell transcriptomic atlas of the developing mouse brain across embryonic stages",
            "Single-cell transcriptomic atlas of the developing human brain across embryonic stages"))
        #expect(TitleSimilarity.score("Spatiotemporal molecular dynamics of the developing human thalamus", journal) < 0.8)
        #expect(TitleSimilarity.score(Self.spatial, "SpatialFormer") < 0.5)
        #expect(TitleSimilarity.score("Attention is all you need", "Attention is not all you need") < 0.92)
    }

    @Test func degenerateInputs() {
        #expect(TitleSimilarity.score("", "Anything") == 0)
        #expect(TitleSimilarity.score("---", "...") == 0)
        let a = "Deep learning for protein structure prediction", b = "Protein structure prediction with deep learning"
        #expect(TitleSimilarity.score(a, b) == TitleSimilarity.score(b, a))
        #expect((0...1).contains(TitleSimilarity.score(a, b)))
        let huge = String(repeating: "word ", count: 5_000)
        #expect((0...1).contains(TitleSimilarity.score(huge, huge + "x")))
    }
}
