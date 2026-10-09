import Foundation
import Testing
@testable import PaperDeckCore

/// Locating the paper on screen (LN §5) in a scratch library: the window title's identifiers,
/// file names and titles; the OCR text's containment on the perturbed layout fixtures
/// (`Fixtures/pdf/{arxiv,cell,nature}_layout.txt`) with negative controls; ambiguity, overrides,
/// recent papers and CJK. Local only: no AI, no network.
@Suite(.serialized) struct PaperLocatorTests {
    struct Library {
        var engine: Engine
        var root: URL
        var arxiv: Paper, cell: Paper, nature: Paper
        var decoys: [Paper]
    }

    static let decoyPages = [
        ["Ocean currents redistribute heat between the tropics and the poles. We analyse thirty years of drifter "
            + "records and find that the western boundary currents strengthened over the period.",
         "Seasonal variability dominates the record near the coast, while interannual signals prevail offshore."],
        ["We present a compiler pass that removes redundant bounds checks in array-heavy loops. The pass proves "
            + "monotonic index ranges with a lightweight abstract interpretation and runs in linear time.",
         "Benchmarks show a twelve percent speedup on numerical kernels without changing program semantics."],
        ["Progenitor cells in the developing retina divide asymmetrically. Lineage tracing in zebrafish shows that "
            + "transcription factor dosage biases the fate of daughter cells toward photoreceptors.",
         "Chromatin accessibility changes precede the expression of fate determinants by several hours."],
    ]

    static func library() async throws -> Library {
        ExplainTextCache.shared.removeAll()
        let (engine, root) = try await ExplainKit.engine()
        let arxiv = try await ExplainKit.paper(engine, title: "A Synthetic Benchmark for Evaluating Coding Agents on Biology Tasks",
                                               pages: try ExplainKit.layoutPages("arxiv_layout"),
                                               ids: PaperIDs(arxivID: "2606.24530", arxivVersion: 2),
                                               pdfName: "2026_Lovelace_A-Synthetic-Benchmark.pdf", originalName: "main.pdf")
        let cell = try await ExplainKit.paper(engine, title: "How to build a synthetic virtual cell with artificial intelligence",
                                              pages: try ExplainKit.layoutPages("cell_layout"), venue: "Cell")
        let nature = try await ExplainKit.paper(engine, title: "Synthetic dynamics of the developing test cortex",
                                                pages: try ExplainKit.layoutPages("nature_layout"),
                                                ids: PaperIDs(doi: "10.1038/s41586-000-00000-0"), originalName: "main.pdf")
        var decoys: [Paper] = []
        for (i, pages) in decoyPages.enumerated() {
            decoys.append(try await ExplainKit.paper(engine, title: "Decoy study number \(i + 1)", pages: pages))
        }
        return Library(engine: engine, root: root, arxiv: arxiv, cell: cell, nature: nature, decoys: decoys)
    }

    static func close(_ lib: Library) async {
        await lib.engine.shutdown()
        try? FileManager.default.removeItem(at: lib.root)
        ExplainTextCache.shared.removeAll()
    }

    static let natureP2 = "Interactions between excitatory and inhibitory neurons were abundant (Fig. 2a–c, Extended Data Fig. 2 "
        + "and Supplementary Fig. 3). We identified regulators of development that guide the differentiation of neuronal subtypes"
    static let arxivP1 = "We introduce a synthetic benchmark of ninety tasks distilled from published papers and evaluate six coding "
        + "agents on it. The best agent solves 41% of the benchmark tasks."
    static let cellP2 = "Virtual cells reproduce perturbation responses across cell types (Figures 2 and 3). Limitations include "
        + "the scarcity of paired perturbation data."

    // MARK: Text

    @Test func perturbedOCRFindsThePaperAndThePage() async throws {
        let lib = try await Self.library()
        let cases: [(String, Paper, Int)] = [(Self.natureP2, lib.nature, 2), (Self.arxivP1, lib.arxiv, 1), (Self.cellP2, lib.cell, 2)]
        for (excerpt, paper, page) in cases {
            let noisy = ExplainKit.perturb(excerpt)
            #expect(noisy != excerpt)
            let m = try #require(await PaperLocator.locate(windowTitle: nil, ocrText: noisy, engine: lib.engine), "\(paper.title)")
            #expect(m.paperID == paper.id && m.page == page && m.via == .text, "\(m)")
            #expect(m.confidence >= PaperLocator.tuning.textAccept)
        }
        await Self.close(lib)
    }

    @Test func negativeControlsMatchNothing() async throws {
        let lib = try await Self.library()
        // Unrelated text, and text sharing the library's vocabulary but not its sentences.
        let unrelated = "Glaciers in the southern range retreated by forty metres a year, exposing moraines that record "
            + "earlier advances; radiocarbon dates from buried soils constrain the timing of each stage."
        let sameWords = "Progenitors of the synthetic cortex generate neurons; development of excitatory subtypes and chromatin "
            + "regulators were profiled across samples with a benchmark of coding agents on biology tasks."
        for text in [unrelated, sameWords] {
            let m = await PaperLocator.locate(windowTitle: nil, ocrText: ExplainKit.perturb(text), engine: lib.engine)
            #expect(m == nil, "\(String(describing: m))")
        }
        // Too short to tell by text.
        #expect(await PaperLocator.locate(windowTitle: nil, ocrText: "neurons were abundant", engine: lib.engine) == nil)
        #expect(await PaperLocator.locate(windowTitle: nil, ocrText: nil, engine: lib.engine) == nil)
        await Self.close(lib)
    }

    @Test func containmentSeparatesTheTrueLocationFromUnrelatedText() throws {
        let pages = try ExplainKit.layoutPages("nature_layout").map(ExplainTextCache.Page.init)
        let hit = try #require(TextMatch.find(ExplainKit.perturb(Self.natureP2), in: pages))
        #expect(hit.page == 2 && hit.score > 0.6, "\(hit)")
        // The match's range points at the excerpt in the page's characters.
        let chars = Array(pages[1].text)
        let found = String(chars[hit.range])
        #expect(found.contains("excitatory") || found.contains("regulators"), "\(found)")
        let other = TextMatch.containment(Self.arxivP1, in: pages[1].text)
        #expect(other < 0.35, "\(other)")
        #expect(TextMatch.containment("", in: pages[1].text) == 0)
        // Spacing, punctuation, case and hyphenation never matter.
        #expect(TextMatch.containment("INTERACTIONS BETWEEN EXCITATORY AND INHIBITORY NEURONS", in: pages[1].text) > 0.95)
        #expect(TextMatch.containment("INTER-\nACTIONS  between excitatory, and inhibitory neurons", in: pages[1].text) > 0.95)
    }

    // MARK: Title

    @Test func windowTitlesMatchByIdentifierFileNameAndTitle() async throws {
        let lib = try await Self.library()
        let e = lib.engine
        let byID = try #require(await PaperLocator.locate(windowTitle: "2606.24530v2.pdf - Google Chrome", ocrText: nil, engine: e))
        #expect(byID.paperID == lib.arxiv.id && byID.via == .identifier && byID.confidence > 0.9)
        let byDOI = try #require(await PaperLocator.locate(windowTitle: "https://doi.org/10.1038/s41586-000-00000-0 - Safari",
                                                           ocrText: nil, engine: e))
        #expect(byDOI.paperID == lib.nature.id && byDOI.via == .identifier)
        let byName = try #require(await PaperLocator.locate(windowTitle: "2026_Lovelace_A-Synthetic-Benchmark.pdf (page 3 of 4) — Preview",
                                                            ocrText: nil, engine: e))
        #expect(byName.paperID == lib.arxiv.id && byName.via == .fileName && byName.page == 3)
        let byCase = try #require(await PaperLocator.locate(windowTitle: "2026_LOVELACE_A-SYNTHETIC-BENCHMARK", ocrText: nil, engine: e))
        #expect(byCase.paperID == lib.arxiv.id && byCase.via == .fileName)
        let byTitle = try #require(await PaperLocator.locate(
            windowTitle: "How to build a synthetic virtual cell with artificial intelligence | Cell Reports", ocrText: nil, engine: e))
        #expect(byTitle.paperID == lib.cell.id && byTitle.via == .windowTitle && byTitle.confidence >= 0.8)
        // A near title still matches; an unrelated or generic one doesn't.
        let near = await PaperLocator.locate(windowTitle: "Synthetic dynamics of the developng test cortex – Mozilla Firefox",
                                             ocrText: nil, engine: e)
        #expect(near?.paperID == lib.nature.id)
        #expect(await PaperLocator.locate(windowTitle: "Weekly grocery list", ocrText: nil, engine: e) == nil)
        #expect(await PaperLocator.locate(windowTitle: "Untitled", ocrText: nil, engine: e) == nil)
        #expect(await PaperLocator.locate(windowTitle: "", ocrText: nil, engine: e) == nil)
        await Self.close(lib)
    }

    @Test func anAmbiguousFileNameIsSettledByTheText() async throws {
        let lib = try await Self.library()
        // Two papers came in as "main.pdf": the name alone matches neither.
        #expect(await PaperLocator.locate(windowTitle: "main.pdf", ocrText: nil, engine: lib.engine) == nil)
        let m = try #require(await PaperLocator.locate(windowTitle: "main.pdf", ocrText: ExplainKit.perturb(Self.natureP2), engine: lib.engine))
        #expect(m.paperID == lib.nature.id && m.page == 2 && m.via == .text)
        await Self.close(lib)
    }

    @Test func titleAndTextAgreeOrTheStrongTextWins() async throws {
        let lib = try await Self.library()
        // The title names the arXiv paper and the text is from it: the title's match, paged by the text.
        let agree = try #require(await PaperLocator.locate(windowTitle: "2026_Lovelace_A-Synthetic-Benchmark.pdf",
                                                           ocrText: Self.arxivP1, engine: lib.engine))
        #expect(agree.paperID == lib.arxiv.id && agree.via == .fileName && agree.page == 1 && agree.confidence >= 0.95)
        // The title names the cell paper but the screen clearly shows the nature paper's text.
        let override = try #require(await PaperLocator.locate(windowTitle: "How to build a synthetic virtual cell with artificial intelligence",
                                                              ocrText: Self.natureP2, engine: lib.engine))
        #expect(override.paperID == lib.nature.id && override.via == .text)
        // A weak text hit elsewhere doesn't beat the title.
        let weak = try #require(await PaperLocator.locate(windowTitle: "How to build a synthetic virtual cell with artificial intelligence",
                                                          ocrText: "Ocean currents redistribute heat today, said the weather report on the radio.",
                                                          engine: lib.engine))
        #expect(weak.paperID == lib.cell.id)
        await Self.close(lib)
    }

    @Test func recentPapersAreTriedFirstAndCJKMatchesWhenACandidateIsKnown() async throws {
        let lib = try await Self.library()
        let zhPages = ["我们在注意力权重上加入熵惩罚，使每个注意力头只关注少量的词元。与随机失活不同，这一惩罚直接作用于分布本身。",
                       "适中的权重就足以让长文档上的训练保持稳定，并且注意力模式在各层之间反复出现。"]
        let zh = try await ExplainKit.paper(lib.engine, title: "注意力正则化", pages: zhPages)
        let excerpt = "适中的权重就足以让长文档上的训练保持稳定，并且注意力模式在各层之间反复出现"
        // The full-text index can't segment Chinese: without a candidate, nothing.
        #expect(await PaperLocator.locate(windowTitle: nil, ocrText: excerpt, engine: lib.engine) == nil)
        // Opened from PaperDeck a moment ago: verified, found on page 2.
        lib.engine.recentOpens.push(paperID: zh.id, at: lib.engine.ctx.now())
        let m = try #require(await PaperLocator.locate(windowTitle: nil, ocrText: excerpt, engine: lib.engine))
        #expect(m.paperID == zh.id && m.page == 2 && m.via == .text)
        // A match is remembered: the next capture of the same paper verifies it first.
        #expect(ExplainTextCache.shared.recentMatches(scope: ObjectIdentifier(lib.engine), now: lib.engine.ctx.now(), within: 60).first == zh.id)
        await Self.close(lib)
    }

    @Test func deletedPapersAreNeverMatched() async throws {
        let lib = try await Self.library()
        try await lib.engine.db.softDelete(pk: lib.nature.pk)
        #expect(await PaperLocator.locate(windowTitle: nil, ocrText: Self.natureP2, engine: lib.engine)?.paperID != lib.nature.id)
        #expect(await PaperLocator.locate(windowTitle: "https://doi.org/10.1038/s41586-000-00000-0", ocrText: nil, engine: lib.engine) == nil)
        await Self.close(lib)
    }

    @Test func titleScores() {
        #expect(PaperLocator.titleScore("Attention Is All You Need", "attention is all you need") == 1)
        #expect(PaperLocator.titleScore("Attention Is All You Need arXiv preprint", "Attention Is All You Need") == 0.95)
        #expect(PaperLocator.titleScore("Attention Is All You", "Attention Is All You Need") == 0.9)
        #expect(PaperLocator.titleScore("Weekly grocery list", "Attention Is All You Need") < 0.5)
        #expect(PaperLocator.titleScore("", "x") == 0)
    }

    @Test func rareTokensSkipStopwordsAndShortWords() {
        let t = TextMatch.rareTokens("The results of the analysis show that oligodendrocytes and astrocytes, which were "
                                     + "observed, differ; however the oligodendrocytes dominate.", limit: 3)
        #expect(t == ["oligodendrocytes", "astrocytes", "dominate"])
        #expect(TextMatch.rareTokens("注意力机制 和 attention") == ["attention"])
    }
}
