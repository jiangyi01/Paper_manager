import Foundation
import Testing
@testable import PaperDeckCore

/// CUX-6, the wrong-paper risk: shared boilerplate (licence footers, journal running heads,
/// "Downloaded from …", URLs, DOIs) is never evidence; a match from text alone needs distinctive
/// content and more overlap when the excerpt is short or the window names another document; an
/// arXiv stamp on the page names it; and the user's "Not this paper" / picked paper is followed.
/// Scratch library, mock providers, local only.
@Suite(.serialized) struct PaperMatchStrengthTests {
    static let footer = "This article is licensed under a Creative Commons Attribution 4.0 International License, which permits "
        + "use, sharing, adaptation, distribution and reproduction in any medium or format, as long as you give appropriate "
        + "credit to the original author(s) and the source, provide a link to the Creative Commons licence, and indicate if "
        + "changes were made."
    static let body = "Blastema cells re-enter the cell cycle within two days of amputation, and their proliferation depends "
        + "on retinoic acid signalling from the wound epidermis."
    static let page2 = "Fin rays regrow in segments; joint formation follows the expression of evx1 along the proximodistal axis "
        + "while osteoblasts dedifferentiate near the stump."

    struct Lib {
        var engine: Engine
        var root: URL
        var fin: Paper
        var other: Paper
        var arxiv: Paper
    }

    static func library() async throws -> Lib {
        ExplainTextCache.shared.removeAll()
        PaperMatchCorrections.shared.removeAll()
        let (engine, root) = try await ExplainKit.engine()
        let fin = try await ExplainKit.paper(engine, title: "Blastema Signalling Drives Zebrafish Fin Regeneration",
                                             pages: [body + " " + footer, page2 + " Downloaded from https://academic.example.org/x on 3 March 2026."],
                                             pdfName: "fin-regeneration.pdf")
        let other = try await ExplainKit.paper(engine, title: "Heart Regeneration in Adult Zebrafish",
                                               pages: ["Cardiomyocytes proliferate after cryoinjury and rebuild the ventricle wall "
                                                       + "within a month. " + footer])
        let arxiv = try await ExplainKit.paper(engine, title: "Sparse Attention for Long Documents",
                                               pages: ["We sparsify attention over long documents."],
                                               ids: PaperIDs(arxivID: "2606.24530", arxivVersion: 2))
        return Lib(engine: engine, root: root, fin: fin, other: other, arxiv: arxiv)
    }

    static func close(_ lib: Lib) async {
        await lib.engine.shutdown()
        try? FileManager.default.removeItem(at: lib.root)
        ExplainTextCache.shared.removeAll()
        PaperMatchCorrections.shared.removeAll()
    }

    // MARK: Boilerplate

    @Test func boilerplateIsStrippedAndTheBodyKept() {
        let text = "Nature | Vol 612 | 15 December 2022 | 523\n" + Self.body + " " + Self.footer
            + " © 2026 The Author(s). All rights reserved. Downloaded from https://www.example.org/doi/10.1000/xyz123 by guest on 3 March 2026."
            + " Correspondence and requests for materials should be addressed to A.L. (ada@example.org)."
        let stripped = Boilerplate.strip(text)
        #expect(stripped.contains("Blastema cells re-enter the cell cycle"), "\(stripped)")
        for gone in ["Creative Commons", "licensed", "Vol 612", "All rights reserved", "Downloaded", "https://", "10.1000",
                     "ada@example.org", "Correspondence", "© 2026"] {
            #expect(!stripped.contains(gone), "\(gone): \(stripped)")
        }
        #expect(Boilerplate.strip(Self.footer).trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
        #expect(Boilerplate.strip("") == "")
    }

    /// Probe P6: the licence footer of a paper outside the library, shown in a window titled after that
    /// other paper, matched a library paper with the same footer (score 1.0).
    @Test func aSharedLicenceFooterMatchesNothing() async throws {
        let lib = try await Self.library()
        let m = await PaperLocator.locate(windowTitle: "Some other preprint I am reading.pdf - Preview", ocrText: Self.footer,
                                          engine: lib.engine)
        #expect(m == nil, "\(String(describing: m))")
        #expect(await PaperLocator.locate(windowTitle: nil, ocrText: Self.footer + " " + Self.footer, engine: lib.engine) == nil)
        // The paper's own sentences beside the footer still find it.
        let real = try #require(await PaperLocator.locate(windowTitle: nil, ocrText: Self.body + " " + Self.footer, engine: lib.engine))
        #expect(real.paperID == lib.fin.id && real.page == 1 && real.via == .text)
        await Self.close(lib)
    }

    @Test func aWindowNamingAnotherDocumentNeedsAStrongTextMatch() async throws {
        let lib = try await Self.library()
        // Half the excerpt is the paper's, half isn't: enough with no window, not from a window about another document.
        let half = Self.body + " Unrelated glaciers retreated forty metres a year while moraines recorded earlier advances near the coast."
        let score = TextMatch.containment(half, in: Self.body + " " + Self.footer)
        try #require(score >= PaperLocator.tuning.textAccept && score < PaperLocator.tuning.textOverride, "\(score)")
        let plain = await PaperLocator.locate(windowTitle: nil, ocrText: half, engine: lib.engine)
        #expect(plain?.paperID == lib.fin.id)
        let foreign = await PaperLocator.locate(windowTitle: "Glacier retreat in the southern range.pdf - Preview", ocrText: half,
                                                engine: lib.engine)
        #expect(foreign == nil, "\(String(describing: foreign))")
        // A generic window name ("main.pdf", "Untitled") says nothing either way.
        #expect(await PaperLocator.locate(windowTitle: "main.pdf - Preview", ocrText: half, engine: lib.engine)?.paperID == lib.fin.id)
        #expect(PaperLocator.namesSpecificDocument(WindowTitle.parse("Glacier retreat in the southern range.pdf - Preview")))
        #expect(!PaperLocator.namesSpecificDocument(WindowTitle.parse("main.pdf - Preview")))
        #expect(!PaperLocator.namesSpecificDocument(WindowTitle.parse("Untitled")))
        await Self.close(lib)
    }

    @Test func shortOrGenericExcerptsNeedMoreThanTheBaseOverlap() {
        let t = PaperLocator.tuning
        #expect(PaperLocator.textOnlyAccept(String(repeating: "abcdefghij ", count: 12), foreignWindow: false) == t.textAccept)
        #expect(PaperLocator.textOnlyAccept("short excerpt of some fifty letters only here", foreignWindow: false) == t.shortTextAccept)
        #expect(PaperLocator.textOnlyAccept(String(repeating: "abcdefghij ", count: 12), foreignWindow: true) == t.textOverride)
        #expect(!TextMatch.isDistinctive("This is shown in the figure and in the table below with more of the data."))
        #expect(TextMatch.isDistinctive(Self.body))
        #expect(TextMatch.isDistinctive("适中的权重就足以让长文档上的训练保持稳定，并且注意力模式在各层之间反复出现"))
    }

    @Test func anArxivStampOnThePageNamesThePaper() async throws {
        let lib = try await Self.library()
        let stamp = "arXiv:2606.24530v2 [cs.CL] 3 Jun 2026"
        #expect(Boilerplate.arxivStamp(stamp) == "2606.24530")
        let m = try #require(await PaperLocator.locate(windowTitle: nil, ocrText: stamp + "\nFigure 2: attention maps", engine: lib.engine))
        #expect(m.paperID == lib.arxiv.id && m.via == .identifier)
        // A citation in a reference list is not a stamp.
        #expect(Boilerplate.arxivStamp("[12] A. Author. Sparse attention. arXiv:2606.24530, 2026.") == nil)
        #expect(await PaperLocator.locate(windowTitle: nil, ocrText: "[12] Sparse attention. arXiv:2606.24530, 2026.", engine: lib.engine) == nil)
        await Self.close(lib)
    }

    // MARK: The user's word

    @Test func notThisPaperIsFollowedAndAPickedPaperWins() async throws {
        let lib = try await Self.library()
        let window = "Blastema Signalling Drives Zebrafish Fin Regeneration - Preview"
        let first = try #require(await PaperLocator.locate(windowTitle: window, ocrText: Self.body, engine: lib.engine))
        #expect(first.paperID == lib.fin.id)
        let scope = ObjectIdentifier(lib.engine)
        PaperMatchCorrections.shared.reject(lib.fin.id, windowTitle: window, excerpt: Self.body, scope: scope, now: lib.engine.ctx.now())
        // Explained again (same window, same text): not that paper — here, no paper at all.
        let again = await PaperLocator.locate(windowTitle: window, ocrText: Self.body, engine: lib.engine)
        #expect(again?.paperID != lib.fin.id, "\(String(describing: again))")
        // The next capture from that window (other text, a page counter in the title) follows it too.
        let next = await PaperLocator.locate(windowTitle: "Blastema Signalling Drives Zebrafish Fin Regeneration (page 2 of 9) - Preview",
                                             ocrText: Self.page2, engine: lib.engine)
        #expect(next?.paperID != lib.fin.id)
        // A picked paper: matched by the user, at full confidence, paged by the text when it is there.
        PaperMatchCorrections.shared.choose(lib.other.id, windowTitle: window, excerpt: Self.body, scope: scope, now: lib.engine.ctx.now())
        let picked = try #require(await PaperLocator.locate(windowTitle: window, ocrText: Self.body, engine: lib.engine))
        #expect(picked.paperID == lib.other.id && picked.via == .user && picked.confidence == 1)
        // Another library (engine) never sees these corrections.
        #expect(PaperMatchCorrections.shared.decisions(windowTitle: window, excerpt: Self.body, scope: ObjectIdentifier(lib.root as NSURL),
                                                       now: lib.engine.ctx.now()).chosen == nil)
        await Self.close(lib)
    }

    @Test func correctionsAreKeyedByTheWindowAndTheExcerptAndExpire() {
        let c = PaperMatchCorrections()
        let scope = ObjectIdentifier(c)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // A generic title keys nothing; the excerpt still does.
        #expect(PaperMatchCorrections.keys(windowTitle: "Untitled", excerpt: nil).isEmpty)
        #expect(PaperMatchCorrections.keys(windowTitle: "main.pdf - Preview", excerpt: Self.body).count == 1)
        #expect(PaperMatchCorrections.keys(windowTitle: "fin-regeneration.pdf (page 2 of 9) - Preview", excerpt: nil)
                == PaperMatchCorrections.keys(windowTitle: "fin-regeneration.pdf — Preview", excerpt: nil))
        c.reject("p1", windowTitle: nil, excerpt: Self.body, scope: scope, now: t0)
        #expect(c.decisions(windowTitle: nil, excerpt: Self.body, scope: scope, now: t0).rejected == ["p1"])
        // A later pick of the same paper lifts its rejection; the newest pick wins.
        c.choose("p1", windowTitle: nil, excerpt: Self.body, scope: scope, now: t0.addingTimeInterval(1))
        let d = c.decisions(windowTitle: nil, excerpt: Self.body, scope: scope, now: t0.addingTimeInterval(2))
        #expect(d.chosen == "p1" && d.rejected.isEmpty)
        // Gone after the lifetime.
        #expect(c.decisions(windowTitle: nil, excerpt: Self.body, scope: scope,
                            now: t0.addingTimeInterval(PaperMatchCorrections.lifetime + 10)).chosen == nil)
    }

    @Test func thePickerFiltersTitlesByEveryWord() {
        let papers = [(id: "a", title: "Blastema Signalling Drives Zebrafish Fin Regeneration"),
                      (id: "b", title: "Heart Regeneration in Adult Zebrafish"), (id: "c", title: "Sparse Attention for Long Documents"),
                      (id: "d", title: "Régénération des nageoires")]
        #expect(PaperMatchCorrections.candidates(papers, query: "zebrafish regen", excluding: nil).map(\.id) == ["a", "b"])
        #expect(PaperMatchCorrections.candidates(papers, query: "ZEBRAFISH", excluding: "a").map(\.id) == ["b"])
        #expect(PaperMatchCorrections.candidates(papers, query: "regeneration des", excluding: nil).map(\.id) == ["d"])
        #expect(PaperMatchCorrections.candidates(papers, query: "", excluding: nil, limit: 2).map(\.id) == ["a", "b"])
        #expect(PaperMatchCorrections.candidates(papers, query: "quantum", excluding: nil).isEmpty)
    }
}
