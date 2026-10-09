import Foundation
import Testing
@testable import PaperDeckCore

/// D6: the tombstone title scan. `TitleBound` must never be below `TitleSimilarity.score` (so the
/// scan finds exactly what a full scan finds), and it must let only a handful of 500 realistic
/// tombstones through to the full score (what made the scan slow: half of them did before).
/// Timing is printed (`PROBE D6 …`); the ≤ 10 ms target is measured in a release build
/// (`./test.sh -c release --filter TombstoneScan`).
@Suite(.serialized) struct TombstoneScanTests {
    /// Ordinary life-science titles: 8–14 words from one shared vocabulary (the worst case for a
    /// word filter — every title shares words with every other).
    static let vocab = ["single-cell", "transcriptomic", "atlas", "human", "cortex", "development", "neural", "progenitor",
                        "organoids", "reveals", "regulation", "chromatin", "accessibility", "lineage", "tracing", "spatial",
                        "dynamics", "microglia", "synaptic", "plasticity", "mouse", "hippocampus", "neurons", "signaling",
                        "pathway", "controls", "differentiation", "stem", "cells", "gene", "expression", "landscape",
                        "inflammation", "metabolic", "programs", "during", "aging", "brain", "circuits", "behavior",
                        "deep", "learning", "model", "predicts", "protein", "structure", "variants", "disease", "risk",
                        "genome-wide", "association", "study", "identifies", "loci", "cortical", "interneurons", "migration"]

    struct RNG {
        var s: UInt64
        mutating func next() -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int(s >> 33) }
    }

    static func title(_ seed: UInt64) -> String {
        var r = RNG(s: seed &* 2654435761 &+ 17)
        let n = 8 + r.next() % 7
        return (0..<n).map { _ in vocab[r.next() % vocab.count] }.joined(separator: " ")
    }

    static let probeTitle = "Spatial transcriptomic atlas of human cortical interneurons reveals migration programs during development"

    /// Variants a real near-duplicate has: a dropped / added word, a typo, split or glued words,
    /// a ligature lost, a subtitle, punctuation, a plural.
    static func variants(_ t: String, seed: UInt64) -> [String] {
        var r = RNG(s: seed)
        let words = t.split(separator: " ").map(String.init)
        var out: [String] = []
        if words.count > 3 {
            var w = words; w.remove(at: r.next() % w.count); out.append(w.joined(separator: " "))
        }
        if let i = words.indices.first(where: { words[$0].count >= 6 }) {
            var w = words
            var chars = Array(w[i]); chars.swapAt(1, 2); w[i] = String(chars)
            out.append(w.joined(separator: " "))
            var s = words
            s[i] = String(words[i].prefix(3)) + " " + String(words[i].dropFirst(3))
            out.append(s.joined(separator: " "))
        }
        if words.count > 2 {
            var g = words; g[0] = g[0] + g[1]; g.remove(at: 1); out.append(g.joined(separator: " "))
        }
        out.append(t + ": insights from " + vocab[r.next() % vocab.count])
        out.append(t.replacingOccurrences(of: "fi", with: "") )
        out.append(t.uppercased() + ".")
        out.append(t + "s")
        return out
    }

    /// The pairs the property is checked on: the fixture pairs, their variants, random titles.
    static func pairs() throws -> [(String, String)] {
        let doc = try DupDetectorFixtureTests.load()
        var titles = doc.pairs.flatMap { [$0.new.title, $0.existing.title] }.compactMap { $0 }.filter { !$0.isEmpty }
        titles += (0..<60).map { title(UInt64($0) + 7_000) }
        titles.append(probeTitle)
        var out: [(String, String)] = []
        for (i, t) in titles.enumerated() {
            for v in variants(t, seed: UInt64(i) + 1) { out.append((t, v)); out.append((v, t)) }
            out.append((t, titles[(i * 7 + 3) % titles.count]))
        }
        for p in doc.pairs {
            if let a = p.new.title, let b = p.existing.title { out.append((a, b)) }
        }
        for i in 0..<400 { out.append((title(UInt64(i)), title(UInt64(i) + 31))) }
        out += [("Representation learning of cortical cells", "Repre sentation learning of cortical cells"),
                ("Neuronal lineages inferred from spatial data", "Neuronal lineage inferred from spatial data"),
                ("Single-cell atlas of the human retina", "A single-cell atlas of the human retinas"),
                ("β-Catenin signalling in vivo", "beta catenin signaling in vivo"),
                ("单细胞转录组图谱揭示人类皮层发育", "单细胞转录组图谱揭示人类皮质发育"),
                ("Classification of cortical cells", "Classication of cortical cells")]
        return out
    }

    @Test func theBoundIsNeverBelowTheScore() throws {
        var checked = 0, reaching = 0
        for (a, b) in try Self.pairs() {
            let na = DedupeText.titleNorm(a), nb = DedupeText.titleNorm(b)
            // The profile's shortcut: a plainly normal title is its own normal form.
            for n in [na, nb] where TitleProfile.isPlainNormal(n) { #expect(TitleSimilarity.normalize(n) == n, "\(n)") }
            let score = TitleSimilarity.score(na, nb)
            let pa = TitleProfile(na), pb = TitleProfile(nb)
            #expect(TitleBound.upperBound(pa, pb) >= score - 1e-9, "\(a) | \(b): bound \(TitleBound.upperBound(pa, pb)) < \(score)")
            if score >= 0.85 {
                reaching += 1
                #expect(TitleBound.mayReach(pa, pb, 0.85), "\(a) | \(b) scores \(score)")
            }
            checked += 1
        }
        #expect(checked > 1_000 && reaching > 150, "\(checked) pairs, \(reaching) reaching the threshold")
    }

    /// The scan returns exactly what scoring every tombstone returns (prefix rule included).
    @Test func plainNormalTitlesAreRecognized() {
        #expect(TitleProfile.isPlainNormal("single cell atlas of the human cortex 2"))
        for s in ["", " atlas", "atlas ", "atlas  cortex", "Atlas", "β catenin", "atlas-cortex", "atlas\tcortex", "café"] {
            #expect(!TitleProfile.isPlainNormal(s), "\(s)")
        }
        #expect(TitleProfile("Beta-Catenin  In Vivo").norm == "beta catenin in vivo")
    }

    @Test func theScanFindsWhatAFullScanFinds() throws {
        var rows: [(pk: Int64, titleNorm: String)] = (0..<200).map { (Int64($0 + 1), DedupeText.titleNorm(Self.title(UInt64($0)))) }
        // Planted near-duplicates of the probe, and of a few random rows.
        for (i, v) in Self.variants(Self.probeTitle, seed: 99).enumerated() {
            rows.append((Int64(1_000 + i), DedupeText.titleNorm(v)))
        }
        let queries = [Self.probeTitle] + (0..<3).map { Self.title(UInt64($0 * 37)) }
            + Self.variants(Self.title(5), seed: 3).prefix(3)
        for q in queries {
            let n = DedupeText.titleNorm(q)
            // D6-1: a shared opening counts only as the detector's "contained" rule (a subtitle).
            let full = rows.filter {
                !$0.titleNorm.isEmpty && (DedupeText.prefixContained(n, $0.titleNorm) || TitleSimilarity.score(n, $0.titleNorm) >= 0.85)
            }.map(\.pk)
            #expect(full.count <= DedupeIndex.historyTitleHitLimit, "\(q): the reference exceeds the in-lock cap")
            #expect(DedupeIndex.tombstoneTitleHits(n, among: rows) == full, "\(q)")
        }
        // The probe finds its planted variants (the scan is not trivially empty).
        let hits = DedupeIndex.tombstoneTitleHits(DedupeText.titleNorm(Self.probeTitle), among: rows)
        #expect(hits.filter { $0 >= 1_000 }.count >= 5, "\(hits)")
    }

    /// The point of D6: the old word bound let ~half of 500 realistic tombstones through to the
    /// full score; this one lets only the real near matches through.
    @Test func fewRealisticTombstonesReachTheFullScore() {
        let query = DedupeText.titleNorm(Self.probeTitle)
        let words = DedupeText.titleWords(query)
        let qp = TitleProfile(query)
        var old = 0, new = 0
        for i in 0..<500 {
            let norm = DedupeText.titleNorm(Self.title(UInt64(i)))
            if DedupeText.mayReachTitleScore(words, norm, 0.85) { old += 1 }
            if TitleBound.mayReach(qp, TitleProfile(norm), 0.85) { new += 1 }
        }
        print("PROBE D6 bound: tombstones reaching the full score \(new)/500 (word bound before: \(old)/500)")
        #expect(old > 100)                 // the realistic set really is the hard case
        #expect(new <= 5)
    }

    /// Timing: the scan alone (500 tombstones, profiles cached as between imports, and cold), and
    /// the whole in-lock match with history on / off (the P1F probe, so the numbers compare).
    @Test func scanTiming() async throws {
        let rows: [(pk: Int64, titleNorm: String)] = (0..<500).map { (Int64($0 + 1), DedupeText.titleNorm(Self.title(UInt64($0)))) }
        let query = DedupeText.titleNorm(Self.probeTitle)
        func median(_ runs: Int, _ body: () -> Void) -> Double {
            var times: [Double] = []
            for _ in 0..<runs {
                let t0 = DispatchTime.now().uptimeNanoseconds
                body()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            return times.sorted()[runs / 2]
        }
        _ = DedupeIndex.tombstoneTitleHits(query, among: rows)          // warm the profile cache
        let warm = median(15) { _ = DedupeIndex.tombstoneTitleHits(query, among: rows) }
        let cold = median(5) {
            for (_, norm) in rows { _ = TitleProfile(norm) }
            _ = DedupeIndex.tombstoneTitleHits(query, among: rows)
        }
        let words = DedupeText.titleWords(query)
        let before = median(5) {
            for (_, norm) in rows where DedupeText.mayReachTitleScore(words, norm, 0.85) {
                _ = TitleSimilarity.score(query, norm)
            }
        }
        print("PROBE D6 scan (500 tombstones): \(String(format: "%.2f", warm)) ms cached, \(String(format: "%.2f", cold)) ms cold; old scan \(String(format: "%.2f", before)) ms")
        // Generous in a debug build (the release target is ≤ 10 ms, measured separately).
        #expect(warm < 250)

        try await DedupeKit.run { env in
            var files: [URL] = []
            for i in 0..<60 { files.append(try env.pdf("p\(i).pdf", title: Self.title(UInt64(i) + 1000))) }
            _ = await env.ingest(files)
            for i in 0..<500 {
                let t = Self.title(UInt64(i))
                try await env.db.insertHistory(DupHistoryRow(paperID: "h\(i)", sha256: nil, doi: nil, arxivID: nil, publishedDOI: nil,
                                                             keys: [], title: t, titleNorm: DedupeText.titleNorm(t), firstSurname: nil,
                                                             year: 2020, page: (0..<128).map { UInt32($0 * 31 + i) }, abstract: nil,
                                                             lastStatus: .done, readCount: 1, doneAt: nil, addedAt: nil,
                                                             purgedAt: DedupeKit.start))
            }
            let probe = env.downloads.appendingPathComponent("probe.pdf")
            try DedupeKit.pdfData(title: Self.probeTitle, doi: nil, body: DedupeKit.body(seed: "probe"), pages: 3, tag: "t").write(to: probe)
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
            print("PROBE D6 in-lock match (60 papers, 500 tombstones): history on \(String(format: "%.1f", on)) ms, off \(String(format: "%.1f", off)) ms → tombstones \(String(format: "%.1f", on - off)) ms")
        }
    }
}
