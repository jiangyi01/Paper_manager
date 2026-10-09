import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fix D6-1: the tombstone title scan inside the commit lock with a realistic focused-lab
/// library — stop words, subtitles, a wider vocabulary, and a fifth of the 500 removed papers
/// opening like the new title ("Spatial transcriptomic …"). The 10-character prefix rule let all of
/// those through unscored (98 of 500), each loaded and compared in the lock: 20.3 ms of tombstone
/// work in a release build against the ≤ 10 ms target. Now a shared opening counts only as the
/// detector's "contained" rule (a subtitle added or cut), and at most `historyTitleHitLimit`
/// tombstones are loaded. Timing is printed (`PROBE D6-1 …`; release: `PAPERDECK_PERF_PROBES=1 ./test.sh -c release -j 4
/// --filter RDTombstoneScan`).
@Suite("Phase 2 fixes RD: tombstone scan", .serialized)
struct RDTombstoneScanFixTests {
    /// The verifier's realistic vocabulary (p2v2 `V2D6ProbeTests`).
    static let extra = ["of", "the", "in", "and", "a", "for", "with", "to", "by", "from", "on", "across", "within", "via", "using",
                        "transcriptome", "proteome", "epigenome", "methylation", "enhancer", "promoter", "CRISPR", "screen", "knockout",
                        "zebrafish", "Drosophila", "organoid", "tumor", "microenvironment", "immune", "T", "cell", "B", "macrophage",
                        "astrocyte", "oligodendrocyte", "myelination", "axon", "dendrite", "spine", "cortex", "thalamus", "striatum",
                        "dopamine", "serotonin", "receptor", "channel", "calcium", "imaging", "two-photon", "optogenetic", "control",
                        "memory", "consolidation", "sleep", "circadian", "rhythm", "feeding", "hypothalamus", "obesity", "insulin",
                        "resistance", "mitochondrial", "autophagy", "lysosome", "stress", "response", "unfolded", "protein", "aggregation",
                        "Alzheimer's", "Parkinson's", "ALS", "neurodegeneration", "tau", "amyloid", "α-synuclein", "β-catenin", "Wnt",
                        "Notch", "Hedgehog", "morphogen", "gradient", "patterning", "embryo", "gastrulation", "somite", "limb", "regeneration",
                        "evolution", "conserved", "primate", "specific", "multi-omic", "integration", "benchmark", "framework", "tool",
                        "resource", "database", "high-throughput", "low-input", "nanopore", "long-read", "sequencing", "assembly", "2",
                        "3D", "4", "10x", "Visium", "MERFISH", "Slide-seq", "single-nucleus", "snRNA-seq", "scATAC-seq", "perturb-seq"]
    static var vocab: [String] { TombstoneScanTests.vocab + extra }

    /// A realistic removed paper's title; a fifth open like the probe ("Spatial transcriptomic …").
    static func title(_ seed: UInt64) -> String {
        var r = TombstoneScanTests.RNG(s: seed &* 2654435761 &+ 99)
        let v = vocab
        var words: [String] = []
        if r.next() % 5 == 0 { words += ["Spatial", "transcriptomic"] }
        let n = 6 + r.next() % 16
        for _ in 0..<n { words.append(v[r.next() % v.count]) }
        var t = words.joined(separator: " ")
        if r.next() % 3 == 0 { t += ": " + (0..<(3 + r.next() % 6)).map { _ in v[r.next() % v.count] }.joined(separator: " ") }
        return t
    }

    static var rows: [(pk: Int64, titleNorm: String)] {
        (0..<500).map { (Int64($0 + 1), DedupeText.titleNorm(Self.title(UInt64($0)))) }
    }

    @Test func aSharedOpeningAloneNoLongerLetsATombstoneThrough() {
        let query = DedupeText.titleNorm(TombstoneScanTests.probeTitle)
        let head = String(query.prefix(10))
        let rows = Self.rows
        let opening = rows.filter { $0.titleNorm.hasPrefix(head) }.count
        let hits = DedupeIndex.tombstoneTitleHits(query, among: rows)
        print("PROBE D6-1 realistic: \(opening)/500 open like the new title; the scan returns \(hits.count)")
        #expect(opening > 50, "the realistic set really is the hard case")
        #expect(hits.count <= 2, "the prefix rule let \(hits.count) tombstones into the lock")
        // Exactly what the detector could still match: the contained rule or the title score.
        let reference = rows.filter {
            DedupeText.prefixContained(query, $0.titleNorm) || TitleSimilarity.score(query, $0.titleNorm) >= DedupeIndex.historyTitleThreshold
        }.map(\.pk)
        #expect(hits == reference)
    }

    /// What the prefix rule was for still matches: the same title with a subtitle added or cut
    /// (score below the threshold), and a short title (< 10 characters) that the long one starts with.
    @Test func truncatedAndSubtitledTitlesAreStillFound() {
        let query = DedupeText.titleNorm(TombstoneScanTests.probeTitle)
        let subtitled = DedupeText.titleNorm(TombstoneScanTests.probeTitle
            + ": a resource of single-nucleus profiles across twelve donors and three developmental stages")
        let cut = DedupeText.titleNorm("Spatial transcriptomic atlas of human cortical interneurons")
        #expect(TitleSimilarity.score(query, subtitled) < DedupeIndex.historyTitleThreshold)
        let rows = Self.rows + [(9_001, subtitled), (9_002, cut)]
        let hits = DedupeIndex.tombstoneTitleHits(query, among: rows)
        #expect(hits.contains(9_001) && hits.contains(9_002), "\(hits)")
        // The other way round: the new title is the short one.
        #expect(DedupeIndex.tombstoneTitleHits(cut, among: [(1, query)]) == [1])
        // A short title shorter than the 10-character head.
        let tiny = "a b c de"
        #expect(DedupeText.prefixContained(tiny + " fgh", tiny) == DedupeIndex.tombstoneTitleHits(tiny + " fgh", among: [(1, tiny)]).contains(1))
    }

    /// However many tombstones qualify, at most `historyTitleHitLimit` are loaded — the best titles,
    /// in the scan's order.
    @Test func theInLockWorkIsCapped() {
        let query = DedupeText.titleNorm(TombstoneScanTests.probeTitle)
        var rows: [(pk: Int64, titleNorm: String)] = (0..<40).map { (Int64($0 + 1), query + " \($0)") }
        rows.append((100, query))
        let hits = DedupeIndex.tombstoneTitleHits(query, among: rows)
        #expect(hits.count == DedupeIndex.historyTitleHitLimit)
        #expect(hits.contains(100), "the exact title is among the kept ones")
        #expect(hits == hits.sorted(), "kept in the scan's order")
    }

    /// The in-lock match with the realistic set, history on vs off (printed; the target is release).
    @Test(.enabled(if: RDPerf.probes, "a timing probe: PAPERDECK_PERF_PROBES=1"))
    func inLockTiming() async throws {
        let query = DedupeText.titleNorm(TombstoneScanTests.probeTitle)
        let rows = Self.rows
        func median(_ runs: Int, _ body: () -> Void) -> Double {
            var times: [Double] = []
            for _ in 0..<runs {
                let t0 = DispatchTime.now().uptimeNanoseconds
                body()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            return times.sorted()[runs / 2]
        }
        _ = DedupeIndex.tombstoneTitleHits(query, among: rows)
        let warm = median(15) { _ = DedupeIndex.tombstoneTitleHits(query, among: rows) }
        let cold = median(5) {
            for (_, norm) in rows { _ = TitleProfile(norm) }
            _ = DedupeIndex.tombstoneTitleHits(query, among: rows)
        }
        print("PROBE D6-1 scan (500 realistic tombstones): \(String(format: "%.2f", warm)) ms cached, \(String(format: "%.2f", cold)) ms cold")

        try await DedupeKit.run { env in
            var files: [URL] = []
            for i in 0..<60 { files.append(try env.pdf("p\(i).pdf", title: Self.title(UInt64(i) + 5000))) }
            _ = await env.ingest(files)
            var rng = TombstoneScanTests.RNG(s: 12345)
            for i in 0..<500 {
                let t = Self.title(UInt64(i))
                try await env.db.insertHistory(DupHistoryRow(paperID: "h\(i)", sha256: nil, doi: nil, arxivID: nil, publishedDOI: nil,
                                                             keys: [], title: t, titleNorm: DedupeText.titleNorm(t), firstSurname: "Smith",
                                                             year: 2018 + i % 8, page: (0..<128).map { _ in UInt32(truncatingIfNeeded: rng.next()) },
                                                             abstract: (0..<128).map { _ in UInt32(truncatingIfNeeded: rng.next()) },
                                                             lastStatus: .done, readCount: 1, doneAt: nil, addedAt: nil,
                                                             purgedAt: DedupeKit.start))
            }
            let probe = env.downloads.appendingPathComponent("probe.pdf")
            try DedupeKit.pdfData(title: TombstoneScanTests.probeTitle, doi: nil, body: DedupeKit.body(seed: "probe"), pages: 3,
                                  tag: "t").write(to: probe)
            let x = try await PDFExtractor().extract(url: probe, fileName: "probe.pdf")
            let s = DedupeIndex.stagedSubject(sha256: "probe", ids: x.ids, title: x.fontTitle ?? "", titleRank: .font,
                                              fileName: "probe.pdf", extracted: x)
            _ = await DedupeIndex.prepare(s, ids: x.ids, ctx: env.ctx, pages: x.pageTexts)
            func matchMedian(_ history: Bool) async -> Double {
                var times: [Double] = []
                for _ in 0..<9 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = await DedupeIndex.match(s, ids: x.ids, excluding: nil, settings: DedupeSettings(history: history),
                                                ctx: env.ctx, pages: x.pageTexts, computeMissing: IntakeActor.signaturesInLock)
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
                return times.sorted()[4]
            }
            let on = await matchMedian(true), off = await matchMedian(false)
            print("PROBE D6-1 in-lock match (60 papers, 500 realistic tombstones): history on \(String(format: "%.1f", on)) ms, off \(String(format: "%.1f", off)) ms → tombstones \(String(format: "%.1f", on - off)) ms")
        }
    }
}
