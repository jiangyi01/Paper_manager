import Foundation
import Testing
@testable import PaperDeckCore

// Regressions of the duplicate check's verification round (v1 D1–D16), the pure parts: title
// kinds, the identity relation when a notice or a short piece came first, short journal versions,
// unknown versions, the fuzzy guards the mutation run found untested, the choice defaults, the
// words, the hold the UI describes, reading counts and the card's related pairs.

/// A subject as the detector sees it (the verifier's probe helper).
private func subject(_ title: String, authors: [String] = ["Ada Lovelace", "Grace Hopper", "Alan Turing"], year: Int? = 2024,
                     doi: String? = nil, published: String? = nil, arxiv: String? = nil, arxivVersion: Int? = nil,
                     pages: Int? = nil, venue: String? = nil, fileName: String? = nil, text: String? = nil) -> DupSubject {
    let ids = PaperIDs(doi: doi, arxivID: arxiv, arxivVersion: arxivVersion, publishedDOI: published)
    return DupSubject(keys: DupKeys.local(ids), doi: doi, title: title, surnames: DedupeText.surnames(authors), year: year,
                      pages: pages, venue: venue, kind: DedupeText.kind(title: title, fileName: fileName),
                      rank: VersionRank.of(ids: ids, venue: venue, fileName: fileName),
                      page: text.flatMap { MinHash.pageSignature(pages: [$0]) }, fileName: fileName)
}

/// D3: the notice / comment / review / supplement words count only with a separator.
@Suite struct DedupeFixKindTests {
    static let articles = [
        "Correction of sickle cell disease by base editing in hematopoietic stem cells",
        "Correction of sickle cell disease by base editing: a phase 1 trial",
        "Response to immune checkpoint blockade in metastatic melanoma",
        "Withdrawal of antidepressant treatment and relapse risk",
        "Withdrawal of antidepressant treatment and relapse risk: a meta-analysis",
        "Retraction of the ventral tegmental area dopamine signal",
        "Addendum to the theory of neural coding",
        "Review of single-cell RNA sequencing methods",
        "Supporting information networks in hospital teams",
        "Reanalysis of single-cell data reveals a rare progenitor",
        "Comment on the role of microglia",
        "Appendix-sparing surgery in children",
        "Supplementary motor area activity during speech",
        "Online data collection for cognitive experiments",
        "Extended data analysis of the cortical atlas",
        "Author response bias in online surveys",
    ]

    @Test(arguments: articles)
    func ordinaryTitlesAreArticles(_ title: String) {
        #expect(DedupeText.kind(title: title) == .article, "\(title)")
    }

    static let notices = [
        "Author Correction: Molecular dynamics of the developing neocortex",
        "Correction to: Molecular dynamics of the developing neocortex",
        "Corrigendum to “Molecular dynamics” [J. Neurosci. 12 (2020) 34–56]",
        "Erratum for the Report “Molecular dynamics” by A. Lovelace",
        "Retraction Note: A study of cortex",
        "RETRACTED: A study of cortex",
        "Expression of Concern: A study of cortex",
        "Editorial Expression of Concern: A study of cortex",
        "Publisher Correction - A study of cortex",
        "Erratum",
        "Retraction",
        "Notice of retraction: A study of cortex",
        "WITHDRAWN: A study of cortex",
        "Gene X in mice (vol 12, pg 34, 2020)",
    ]

    @Test(arguments: notices)
    func noticesStayNotices(_ title: String) {
        #expect(DedupeText.kind(title: title) == .notice, "\(title)")
    }

    static let comments = [
        "Reply to: Molecular dynamics of the developing neocortex",
        "Reply to “Molecular dynamics of the developing neocortex”",
        "Response to Comment on “Molecular dynamics”",
        "Comment on “Molecular dynamics of the developing neocortex”",
        "Matters arising from Wang et al.",
        "Reply to Wang et al.",
        "Authors' reply",
        "Re: the origin of species revisited",
    ]

    @Test(arguments: comments)
    func commentsStayComments(_ title: String) {
        #expect(DedupeText.kind(title: title) == .comment, "\(title)")
    }

    @Test func reviewsAndSupplementsNeedTheirOwnWords() {
        for t in ["Peer review file", "Decision letter: A study", "Author response: A study", "Review of: A study",
                  "Reviewer #1 (Public review): A study", "Response to reviewers", "Reviewer report"] {
            #expect(DedupeText.kind(title: t) == .review, "\(t)")
        }
        for t in ["Supplementary Information", "Supplementary information for spatial atlas", "Supplementary Figure 3",
                  "Supplementary Materials and Methods", "Extended Data for the atlas", "Appendix", "Appendix A: proofs",
                  "Online Methods", "SI Appendix"] {
            #expect(DedupeText.kind(title: t) == .supplement, "\(t)")
        }
    }

    /// Two copies of such an article are found (before: never compared, or "a comment on a paper you have").
    @Test func copiesOfTheseArticlesMatchAsArticles() throws {
        let t = "Response to immune checkpoint blockade in metastatic melanoma"
        let fuzzy = try #require(DupDetector.compare(subject(t), subject(t)))
        #expect(fuzzy.band == .likely && fuzzy.relation.isSameWork)
        let doi = "10.1038/s41591-024-00001-1"
        let same = try #require(DupDetector.compare(subject(t, doi: doi), subject(t, doi: doi)))
        #expect(same.band == .certain && same.relation == .sameWork)
    }

    /// Two copies of one real notice (the same DOI): two copies, not a notice of the notice.
    @Test func twoCopiesOfOneNoticeAreCopies() throws {
        let t = "Author Correction: Molecular dynamics of the developing neocortex"
        let doi = "10.1038/s41586-024-00003-3"
        let c = try #require(DupDetector.compare(subject(t, doi: doi, pages: 1), subject(t, doi: doi, pages: 1)))
        #expect(c.band == .certain && c.relation.isSameWork)
        // Without an identifier their shared title (two corrections of one paper share it) proves nothing.
        #expect(DupDetector.compare(subject(t), subject(t)) == nil)
        let text = DedupeKit.body(seed: "one notice")
        #expect(DupDetector.compare(subject(t, text: text), subject(t, text: text))?.band == .likely)
        #expect(DupDetector.compare(subject(t, authors: [], text: text), subject(t, authors: [], text: text))?.band == .possible)
    }
}

/// D2, D7, D12 and the fuzzy guards the mutation run found untested (V4, V5, V6, V7, V9).
@Suite struct DedupeFixDetectorTests {
    static let title = "Spatial transcriptomics of the human cortex"

    /// D2: a notice (printing the article's DOI) imported first, then the article: the article is the newer side.
    @Test func theArticleAfterItsNoticeIsTheOneToKeep() throws {
        let doi = "10.1038/s41586-024-00003-3"
        let notice = subject("Author Correction: \(Self.title)", doi: doi, pages: 1)
        let article = subject(Self.title, doi: doi, pages: 14)
        let c = try #require(DupDetector.compare(article, notice))
        #expect(c.band == .certain && c.relation == .newerVersion && c.newerSide == .new)
        // A comment, a review file or a short piece printing the DOI, imported first: the same.
        for first in [subject("Reply to: \(Self.title)", doi: doi, pages: 2), subject("Peer review file", doi: doi, pages: 9),
                      subject("A new map of the human cortex", doi: doi, pages: 2)] {
            let r = try #require(DupDetector.compare(article, first))
            #expect(r.relation == .newerVersion && r.newerSide == .new, "\(first.title)")
        }
        // The other way round stays a notice of the paper.
        #expect(DupDetector.compare(notice, article)?.relation == .correction)
    }

    /// D7: a short journal version (an application note) of a long preprint is the newer version.
    @Test func aShortJournalVersionOfALongPreprintIsNewer() throws {
        let t = "fastdedup: a tool for deduplicating single-cell reads"
        let journal = "10.1093/bioinformatics/btae001"
        let preprint = subject(t, year: 2024, doi: "10.1101/2024.01.01.000123", published: journal, pages: 12)
        for pages in [2, 3, 4] {
            let c = try #require(DupDetector.compare(subject(t, year: 2025, doi: journal, pages: pages), preprint))
            #expect(c.relation == .newerVersion && c.newerSide == .new, "\(pages) pages")
        }
        // The preprint arriving after its short journal version: an older version, not the paper over an insert.
        let older = try #require(DupDetector.compare(preprint, subject(t, year: 2025, doi: journal, pages: 3)))
        #expect(older.relation == .olderVersion && older.newerSide == .existing)
    }

    /// V9: a short piece printing the paper's identifier under another title is not the paper.
    @Test func aShortInsertIsNotThePaper() throws {
        let doi = "10.1038/s41586-024-00003-3"
        let article = subject(Self.title, doi: doi, pages: 14)
        let views = subject("A new map of the human cortex", doi: doi, pages: 2)
        let c = try #require(DupDetector.compare(views, article))
        #expect(c.band == .certain && c.relation == .supplement && c.newerSide == .existing)
        // Even when it prints the journal DOI of a preprint in the library (newer by rank only).
        let preprint = subject(Self.title, doi: "10.1101/2024.01.01.000555", published: doi, pages: 12)
        #expect(DupDetector.compare(views, preprint)?.relation == .supplement)
        // A one-page file is never the paper's version.
        #expect(DupDetector.compare(subject(Self.title, doi: doi, pages: 1), preprint)?.relation == .supplement)
    }

    /// D12: "the same version" only when both versions are known, or the text is the same.
    @Test func sameVersionNeedsKnownVersionsOrTheSameText() throws {
        let doi = "10.1101/2024.01.01.000777"
        let unknown = try #require(DupDetector.compare(subject(Self.title, doi: doi), subject(Self.title, doi: doi)))
        #expect(unknown.relation == .sameWork)
        let text = DedupeKit.body(seed: "version text")
        #expect(DupDetector.compare(subject(Self.title, doi: doi, text: text), subject(Self.title, doi: doi, text: text))?.relation
                == .sameVersion)
        let v2 = subject(Self.title, arxiv: "2401.01234", arxivVersion: 2)
        #expect(DupDetector.compare(v2, subject(Self.title, arxiv: "2401.01234", arxivVersion: 2))?.relation == .sameVersion)
        #expect(!VersionRank.sameVersion(VersionRank(tier: .preprint), VersionRank(tier: .preprint)))
        #expect(VersionRank.sameVersion(VersionRank(tier: .published, version: 3), VersionRank(tier: .published, version: 3)))
    }

    /// D12: a bioRxiv file names its version when its printed DOI doesn't.
    @Test func biorxivVersionsFromFileNames() throws {
        let doi = "10.1101/2024.01.01.000777"
        #expect(VersionRank.biorxivFileVersion(fileName: "2024.01.01.000777v2.full.pdf", doi: doi) == 2)
        #expect(VersionRank.biorxivFileVersion(fileName: "2024.01.01.000777v12.pdf", doi: "10.64898/2024.01.01.000777") == 12)
        #expect(VersionRank.biorxivFileVersion(fileName: "123456v3.full.pdf", doi: "10.1101/123456") == 3)
        #expect(VersionRank.biorxivFileVersion(fileName: "2024.01.01.000778v2.full.pdf", doi: doi) == nil)   // another id
        #expect(VersionRank.biorxivFileVersion(fileName: "2024.01.01.000777v2.full.pdf", doi: "10.1038/x") == nil)
        #expect(VersionRank.biorxivFileVersion(fileName: "paper.pdf", doi: doi) == nil)
        let v1 = subject(Self.title, doi: doi, fileName: "2024.01.01.000777v1.full.pdf")
        let v2 = subject(Self.title, doi: doi, fileName: "2024.01.01.000777v2.full.pdf")
        let c = try #require(DupDetector.compare(v2, v1))
        #expect(c.relation == .newerVersion && c.newerSide == .new)
    }

    /// V4: generic titles by the same author are never compared by title.
    @Test func genericTitlesOfOneAuthorAreNotTheSamePaper() {
        for t in ["Introduction", "Editorial", "Book review", "In this issue"] {
            #expect(DupDetector.compare(subject(t, authors: ["Ada Lovelace"]), subject(t, authors: ["Ada Lovelace"])) == nil, "\(t)")
        }
    }

    /// V5: a notice, a comment or a review file in the library is never the same work as a paper —
    /// not even with the same text and authors.
    @Test func anExistingNoticeIsNeverMatchedFuzzily() {
        let text = DedupeKit.body(seed: "veto text")
        let article = subject(Self.title, text: text)
        for e in ["Retraction Note: \(Self.title)", "Reply to: \(Self.title)", "Decision letter: \(Self.title)"] {
            #expect(DupDetector.compare(article, subject(e, text: text)) == nil, "\(e)")
        }
        #expect(DupDetector.compare(subject("Peer review file", text: text), article) == nil)
    }

    /// V6: a CJK title is held to a stricter title threshold (one changed character is not "likely").
    @Test func cjkTitlesAreStricter() throws {
        let a = "单细胞转录组图谱：人类大脑皮层发育过程中的神经元多样性"
        let b = "单细胞转录组图谱：人类大脑皮层发育过程中的神经元多元性"
        let score = TitleSimilarity.score(a, b)
        #expect(score >= 0.97 && score < 1, "\(score)")
        #expect(DupDetector.compare(subject(a), subject(b))?.band == .possible)
        // The identical CJK title is still likely.
        #expect(DupDetector.compare(subject(a), subject(a))?.band == .likely)
    }

    /// V7: the year tolerance — one year between two final versions, two with a preprint.
    @Test func yearTolerance() {
        let t = "Robust benchmarking of single-cell integration methods"
        func band(_ y1: Int, _ y2: Int, arxiv: Bool = false) -> DupBand? {
            DupDetector.compare(subject(t, year: y1, arxiv: arxiv ? "2401.05555" : nil), subject(t, year: y2))?.band
        }
        #expect(band(2024, 2023) == .likely)
        #expect(band(2024, 2022) == .possible)
        #expect(band(2024, 2021) == .possible)
        #expect(band(2024, 2020) == nil)
        #expect(band(2024, 2022, arxiv: true) == .likely)
        #expect(band(2024, 2021, arxiv: true) == .possible)
    }

    /// D6: the tombstone scan's cheap bound never drops a title the score would keep.
    @Test func theTitleBoundNeverDropsAMatch() throws {
        let doc = try DupDetectorFixtureTests.load()
        var pairs = doc.pairs.compactMap { p -> (String, String)? in
            guard let a = p.new.title, let b = p.existing.title, !a.isEmpty, !b.isEmpty else { return nil }
            return (a, b)
        }
        pairs += [("Representation learning of cortical cells", "Repre sentation learning of cortical cells"),
                  ("Neuronal lineages inferred from spatial data", "Neuronal lineage inferred from spatial data"),
                  ("Single-cell atlas of the human retina", "A single-cell atlas of the human retinas"),
                  ("Single-Cell RNA-seq reveals neuronal diversity", "Single cell RNA seq reveals neuronal diversity.")]
        var kept = 0
        for (x, y) in pairs {
            for (a, b) in [(x, y), (y, x), (x, x)] {
                let na = DedupeText.titleNorm(a), nb = DedupeText.titleNorm(b)
                if TitleSimilarity.score(na, nb) >= 0.85 {
                    #expect(DedupeText.mayReachTitleScore(DedupeText.titleWords(na), nb, 0.85), "\(a) | \(b)")
                    kept += 1
                }
            }
        }
        #expect(kept > pairs.count + 10)
        // …and drops unrelated ones.
        let w = DedupeText.titleWords(DedupeText.titleNorm("Removed paper number 12 about cortex organoid development"))
        #expect(!DedupeText.mayReachTitleScore(w, DedupeText.titleNorm("Study of synthetic cortex development in organoids and more"), 0.85))
    }
}

/// D8, D9, D10, D16: defaults, the hold the UI describes, reading counts, words, the card.
@Suite struct DedupeFixModelTests {
    func paper(_ status: PaperStatus = .toRead) -> Paper {
        Paper(pk: 1, sha256: "e", fileSize: 1, ids: PaperIDs(doi: "10.1/x"), title: "X", folder: "Papers/E", pdfName: "E.pdf",
              originalName: "e.pdf", status: status)
    }

    func review(_ relation: DupRelation, parked: Bool = true, band: DupBand = .certain, held: DupHeldIntent? = nil) -> DupReview {
        DupReview(newPaperID: parked ? nil : "n", existingPaperID: "e", band: band, score: 1, createdAt: Date(),
                  newPaperPK: parked ? nil : 2, existingPaperPK: 1, relation: relation, newerSide: .existing,
                  pendingID: parked ? "p" : nil, held: held)
    }

    /// D8: a correction or a comment is kept linked as related by default; a supplement is attached.
    @Test func relatedItemsDefaultToKeepBoth() {
        for relation in [DupRelation.correction, .comment] {
            let r = DupChoiceRules.choices(review(relation), newIDs: PaperIDs(doi: "10.1/x"), existing: paper(), history: nil)
            #expect(r.default == .keepBoth && r.choices == [.keepBoth, .attachSupplement, .skip], "\(relation)")
        }
        let s = DupChoiceRules.choices(review(.supplement), newIDs: PaperIDs(doi: "10.1/x"), existing: paper(), history: nil)
        #expect(s.default == .attachSupplement && s.choices == [.attachSupplement, .keepBoth, .skip])
    }

    /// D9: what a review holds is what its intent says, not its band.
    @Test func theHoldIsWhatTheReviewHeld() {
        #expect(review(.sameWork, parked: false, band: .likely, held: DupHeldIntent(scheduleHeld: true)).hold == .scheduleAndAI)
        #expect(review(.sameWork, parked: false, band: .certain, held: DupHeldIntent(scheduleHeld: false)).hold == .aiOnly)
        #expect(review(.sameWork, parked: false, band: .likely, held: nil).hold == .none)            // a library check
        // B3: a held paper stays held whatever the band says — the AI judge may move a held review to
        // "possible", and it never releases anything (only the user's answer does).
        #expect(review(.sameWork, parked: false, band: .possible, held: DupHeldIntent(scheduleHeld: true)).hold == .scheduleAndAI)
        #expect(review(.sameWork, parked: false, band: .possible, held: nil).hold == .none)
        #expect(review(.sameWork, parked: true).hold == .none)
    }

    /// D10: only finished readings count.
    @Test func readCountsCountFinishedReadings() {
        let t = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(ReadingCycle.readCount([], doneAt: nil) == 0)
        #expect(ReadingCycle.readCount([], doneAt: t) == 1)
        #expect(ReadingCycle.readCount([ReadingCycle(n: 1, startedAt: t, reason: "first")], doneAt: nil) == 0)
        let reread = [ReadingCycle(n: 1, startedAt: t, doneAt: t, reason: "first"), ReadingCycle(n: 2, startedAt: t, reason: "reread")]
        #expect(ReadingCycle.readCount(reread, doneAt: nil) == 1)
        #expect(ReadingCycle.readCount(reread, doneAt: t) == 2)
        #expect(ReadingCycle.readCount([ReadingCycle(n: 2, startedAt: t, reason: "again")], doneAt: nil) == 1)
    }

    /// D16: the preprint label in Chinese.
    @Test func thePreprintLabelInBothLanguages() {
        let r = VersionRank(tier: .preprint, version: 2)
        #expect(DupExplainer.versionLabel(venue: nil, rank: r, lang: .en) == "Preprint v2")
        #expect(DupExplainer.versionLabel(venue: nil, rank: r, lang: .zh) == "预印本 v2")
        #expect(DupExplainer.versionLabel(venue: nil, rank: VersionRank(tier: .preprint), lang: .zh) == "预印本")
        #expect(DupExplainer.versionLabel(venue: "bioRxiv", rank: r, lang: .zh) == "bioRxiv v2")
    }

    /// D16: a pair kept linked as related keeps its relation on the card (distinctFrom lists it too).
    @Test func theCardKeepsRelatedPairs() throws {
        let p = Paper(id: "aaaa", sha256: "bbbb", fileSize: 1, title: "T", folder: "Papers/T", pdfName: "T.pdf", originalName: "T.pdf",
                      addedAt: DedupeKit.start, updatedAt: DedupeKit.start)
        let entries = ["cccc", "dddd", CardSidecar.relatedPartnerEntry(id: "DDDD", relation: "correction")]
        let card = CardSidecar(paper: p, checklist: [], categoryName: nil, tags: [], aiProvider: nil, aiModel: nil, distinctFrom: entries)
        #expect(card.distinctFrom == ["cccc", "dddd"])
        #expect(card.relatedTo == [CardSidecar.RelatedEntry(id: "dddd", relation: "correction")])
        let json = try #require(try JSONSerialization.jsonObject(with: try card.encoded()) as? [String: Any])
        #expect(json["distinctFrom"] as? [String] == ["cccc", "dddd"])
        #expect((json["relatedTo"] as? [[String: Any]])?.first?["relation"] as? String == "correction")
        let m = try CardSidecar.decoded(from: try card.encoded()).toModels(folder: "Papers/T")
        #expect(m.distinctFrom == ["cccc", "dddd"] && m.relatedTo == [CardSidecar.RelatedEntry(id: "dddd", relation: "correction")])
        // Plain ids are not related entries; a card without related pairs has no key.
        #expect(CardSidecar.relatedPartner("cccc") == nil)
        let plain = CardSidecar(paper: p, checklist: [], categoryName: nil, tags: [], aiProvider: nil, aiModel: nil, distinctFrom: ["cccc"])
        #expect((try JSONSerialization.jsonObject(with: try plain.encoded()) as? [String: Any])?["relatedTo"] == nil)
    }
}

/// The verifier's family members (same first author, same year): never a match — without
/// identifiers, or with a DOI on one side only.
@Suite struct DedupeFixFamilyTests {
    static let pairs: [(String, String)] = [
        ("MHC class I antigen presentation in dendritic cells of the spleen", "MHC class II antigen presentation in dendritic cells of the spleen"),
        ("Type I interferon signaling drives neuroinflammation in the aging brain", "Type II interferon signaling drives neuroinflammation in the aging brain"),
        ("Mitochondrial complex I deficiency causes neurodegeneration in mice", "Mitochondrial complex II deficiency causes neurodegeneration in mice"),
        ("Influenza A virus hemagglutinin structure at atomic resolution", "Influenza B virus hemagglutinin structure at atomic resolution"),
        ("Hepatitis B virus reactivation during immunotherapy in cancer patients", "Hepatitis C virus reactivation during immunotherapy in cancer patients"),
        ("Single-cell atlas of hippocampal neurogenesis in mice", "Single-cell atlas of hippocampal neurogenesis in rats"),
        ("Single-cell atlas of hippocampal neurogenesis in humans", "Single-cell atlas of hippocampal neurogenesis in mice"),
        ("Treatment outcomes in HER2-positive metastatic breast cancer", "Treatment outcomes in HER2-negative metastatic breast cancer"),
        ("Upregulation of synaptic genes in autism spectrum disorder cortex", "Downregulation of synaptic genes in autism spectrum disorder cortex"),
        ("Sex differences in male mouse social behavior circuits", "Sex differences in female mouse social behavior circuits"),
        ("第一部分：单细胞测序方法的系统综述与比较", "第二部分：单细胞测序方法的系统综述与比较"),
        ("人类大脑皮层发育的单细胞转录组图谱研究", "小鼠大脑皮层发育的单细胞转录组图谱研究"),
        ("Glucocorticoid receptor activation in CD4 T cells", "Glucocorticoid receptor activation in CD8 T cells"),
    ]

    @Test func familyMembersAreNeverMatched() {
        for (a, b) in Self.pairs {
            #expect(DupDetector.compare(subject(a), subject(b)) == nil, "\(a) | \(b)")
            #expect(DupDetector.compare(subject(a, doi: "10.1016/j.cell.2024.01.001"), subject(b)) == nil, "\(a) + DOI")
        }
    }
}
