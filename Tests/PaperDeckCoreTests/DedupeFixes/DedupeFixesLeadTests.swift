import Foundation
import Testing
@testable import PaperDeckCore

// Lead fixes after the phase-1 fix verification (regressions #3 and #4).

@Suite struct DedupeFixesLeadTests {
    private func subject(_ title: String, arxiv: String, version: Int, text: String) -> DupSubject {
        let ids = PaperIDs(doi: nil, arxivID: arxiv, arxivVersion: version, publishedDOI: nil)
        return DupSubject(keys: DupKeys.local(ids), doi: nil, title: title,
                          surnames: DedupeText.surnames(["Ada Lovelace", "Grace Hopper"]), year: 2024,
                          pages: 12, venue: nil, kind: DedupeText.kind(title: title, fileName: nil),
                          rank: VersionRank.of(ids: ids, venue: nil, fileName: nil),
                          page: MinHash.pageSignature(pages: [text]), fileName: nil)
    }

    /// #3: a fuzzy match is "same version" only with known-equal versions AND near-identical text.
    @Test func fuzzySameVersionNeedsBothVersionsAndText() {
        let a = subject("Graph neural networks for cell typing", arxiv: "2601.00001", version: 1, text: "alpha")
        let b = subject("Graph neural networks for cell typing", arxiv: "2601.00002", version: 1, text: "beta")
        #expect(!DupDetector.sameVersionFuzzy(a, b, pageX: 0.4))          // both v1, different text
        #expect(DupDetector.sameVersionFuzzy(a, b, pageX: 0.95))          // both v1, same text
        let unknown = VersionRank(tier: .preprint)
        var c = a; c.rank = unknown
        var d = b; d.rank = unknown
        #expect(!DupDetector.sameVersionFuzzy(c, d, pageX: 0.95))         // versions unknown
        #expect(DupDetector.sameVersion(a, b, pageX: 0.4))                // identifier path unchanged
    }

    /// #4: "Online …" is a supplement only as a bare section title.
    @Test func onlineArticleTitlesAreNotSupplements() {
        for t in ["Online methods for single-cell lineage tracing",
                  "Online data from wearable sensors predicts relapse",
                  "Online learning of synaptic plasticity rules"] {
            #expect(DedupeText.kind(title: t, fileName: nil) != .supplement, "\(t)")
        }
        for t in ["Online Methods", "Online methods: statistics", "Online supplementary material"] {
            #expect(DedupeText.kind(title: t, fileName: nil) == .supplement, "\(t)")
        }
    }
}
