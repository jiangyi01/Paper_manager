import Foundation
import Testing
@testable import PaperDeckCore

/// The pure pieces of the duplicate check: DOI families, identity tokens, kinds and vetoes,
/// surnames, the FTS tokens, version ranks, MinHash stability, the choice rules, the words.
@Suite struct DOIFamilyTests {
    @Test func versionEncodingDOIsShareOneKey() {
        #expect(DOIFamily.key("10.7554/eLife.98765.1") == "elife:98765")
        #expect(DOIFamily.key("10.7554/eLife.98765.3") == "elife:98765")
        #expect(DOIFamily.key("https://doi.org/10.7554/elife.98765") == "elife:98765")
        #expect(DOIFamily.key("10.12688/f1000research.12345.1") == DOIFamily.key("10.12688/f1000research.12345.2"))
        #expect(DOIFamily.key("10.12688/wellcomeopenres.17456.2") == "10.12688/wellcomeopenres.17456")
        #expect(DOIFamily.key("10.21203/rs.3.rs-1234567/v1") == DOIFamily.key("10.21203/rs.3.rs-1234567/v2"))
        #expect(DOIFamily.key("10.20944/preprints202608.0213.v1") == "10.20944/preprints202608.0213")
        #expect(DOIFamily.key("10.26434/chemrxiv-2024-abc12-v2") == "10.26434/chemrxiv-2024-abc12")
        #expect(DOIFamily.key("10.7287/peerj.preprints.27353v2") == "10.7287/peerj.preprints.27353")
    }

    @Test func biorxivPrefixesAndVersionsAreOneWork() {
        // Regression of `Database.sameWorkDOIs`: both prefixes, version suffix dropped.
        let a = DOIFamily.key("10.1101/2024.01.02.573456"), b = DOIFamily.key("10.64898/2024.01.02.573456v2")
        #expect(a == "biorxiv:2024.01.02.573456" && a == b)
        #expect(DOIFamily.key("10.1101/123456") == "biorxiv:123456")
        // Cold Spring Harbor journals share 10.1101 but are their own DOIs.
        #expect(DOIFamily.key("10.1101/gr.277000.122") == "10.1101/gr.277000.122")
    }

    @Test func arxivDOIAndIdMeet() {
        #expect(DOIFamily.key("10.48550/arXiv.2402.05678") == "arxiv:2402.05678")
        #expect(DupKeys.arxivToken("2402.05678v3") == "arxiv:2402.05678")
        #expect(DupKeys.arxivToken("arXiv:2402.05678") == "arxiv:2402.05678")
        #expect(DupKeys.arxivToken("math.GT/0309136") == "arxiv:math/0309136")
        #expect(DupKeys.arxivToken("not an id") == nil)
        #expect(DOIFamily.key("10.1038/s41586-024-08351-7") == "10.1038/s41586-024-08351-7")
        #expect(DOIFamily.key("nonsense") == nil)
    }

    @Test func versionsFromDOIs() {
        #expect(DOIFamily.version("10.7554/eLife.98765.3") == 3)
        #expect(DOIFamily.version("10.21203/rs.3.rs-1234567/v2") == 2)
        #expect(DOIFamily.version("10.1038/s41586-024-08351-7") == nil)
    }

    @Test func localKeysAndRecordKeys() {
        let keys = DupKeys.local(PaperIDs(doi: "10.1101/2024.01.02.573456", arxivID: "2401.01234",
                                          publishedDOI: "10.1038/s41586-025-01234-5"))
        #expect(keys.map(\.kind) == [.doi, .publishedDOI, .arxiv])
        #expect(keys.allSatisfy { $0.source == .local })
        let record = BiblioMetadata(source: .crossref, relations: [
            WorkRelation(kind: .hasPreprint, doi: "10.1101/2023.11.11.566789"),
            WorkRelation(kind: .isVersionOf, doi: "10.5281/zenodo.1"),
            WorkRelation(kind: .isCommentOn, doi: "10.1/comment"),
        ], openAlexID: "W123456")
        let rk = DupKeys.fromRecord(record)
        #expect(rk.map(\.kind) == [.preprintDOI, .versionDOI, .openalex])
        #expect(rk.map(\.value) == ["biorxiv:2023.11.11.566789", "10.5281/zenodo.1", "openalex:w123456"])
    }
}

@Suite struct TitleNormalizationTests {
    @Test func kinds() {
        #expect(DedupeText.kind(title: "Author Correction: Molecular dynamics") == .notice)
        #expect(DedupeText.kind(title: "Retraction Note: A study") == .notice)
        #expect(DedupeText.kind(title: "Gene X in mice (vol 12, pg 34, 2020)") == .notice)
        #expect(DedupeText.kind(title: "Reply to: Molecular dynamics of the neocortex") == .comment)
        #expect(DedupeText.kind(title: "Matters arising from Wang et al.") == .comment)
        #expect(DedupeText.kind(title: "Supplementary Information") == .supplement)
        #expect(DedupeText.kind(title: "Extended Data for the atlas") == .supplement)
        #expect(DedupeText.kind(title: "Peer review file") == .review)
        #expect(DedupeText.kind(title: "Introduction") == .generic)
        #expect(DedupeText.kind(title: "Editorial") == .generic)
        #expect(DedupeText.kind(title: "Molecular dynamics of the developing neocortex") == .article)
        #expect(DedupeText.kind(title: "x", workType: "component") == .supplement)
        #expect(DedupeText.kind(title: "Any title of a paper here", relations: [WorkRelation(kind: .correctionOf, doi: "10.1/x")]) == .notice)
        #expect(DedupeText.kind(title: "单细胞图谱揭示人类大脑皮层发育") == .article)
        #expect(DedupeText.kind(title: "图谱") == .generic)
    }

    @Test func supplementFileNames() {
        for name in ["mmc1.pdf", "MMC2.pdf", "41586_2025_1234_MOESM1_ESM.pdf", "media-1.pdf", "pone.0270001.s001.pdf",
                     "pnas.2101234.sapp.pdf", "paper_supp.pdf", "SI_appendix.pdf"] {
            #expect(DedupeText.isSupplementFileName(name), "\(name)")
        }
        for name in ["s41586-024-08351-7.pdf", "2604.09554v2.pdf", "Wang_2024_Nature.pdf", "media.pdf"] {
            #expect(!DedupeText.isSupplementFileName(name), "\(name)")
        }
    }

    @Test func noticeTargets() {
        #expect(DedupeText.noticeTarget("Author Correction: Molecular dynamics of X") == "Molecular dynamics of X")
        #expect(DedupeText.noticeTarget("Reply to: “Molecular dynamics of X”") == "Molecular dynamics of X")
        #expect(DedupeText.noticeTarget("Molecular dynamics of X") == nil)
    }

    @Test func discriminatorsCatchFamilyMembers() {
        func same(_ a: String, _ b: String) -> Bool { DedupeText.sameDiscriminators(DedupeText.titleNorm(a), DedupeText.titleNorm(b)) }
        #expect(!same("Functional assessment of BRCA1 variants", "Functional assessment of BRCA2 variants"))
        #expect(!same("Hsp70 client recognition", "Hsp90 client recognition"))
        #expect(!same("Global cancer statistics 2018", "Global cancer statistics 2020"))
        #expect(!same("Computational methods, part I", "Computational methods, part II"))
        #expect(!same("Atlas of the mouse retina", "Atlas of the human retina"))
        #expect(!same("Screening in vivo", "Screening in vitro"))
        #expect(!same("TGF-β signaling in cancer", "TGF-γ signaling in cancer"))
        #expect(same("COVID-19 outcomes in a cohort", "COVID 19 outcomes in a cohort"))
        #expect(same("A 2,000-patient cohort", "A 2000 patient cohort"))
        #expect(same("Molecular dynamics of the developing neocortex", "Molecular Dynamics of the Developing Neocortex."))
    }

    @Test func surnamesDropGroupsAndFold() {
        #expect(DedupeText.surnames(["The Tabula Sapiens Consortium", "Robert Jones", "Kriegstein AR", "Wang, Li", "José Núñez"])
                == ["jones", "kriegstein", "wang", "nunez"])
        #expect(DedupeText.surnames(Array(repeating: "Ada Lovelace", count: 3)) == ["lovelace"])
        #expect(DedupeText.attributeSurnames("Li Wang, Ada Lovelace") == ["wang", "lovelace"])
        #expect(DedupeText.attributeSurnames("Wang, Li") == ["wang"])
        #expect(DedupeText.attributeSurnames(nil).isEmpty)
    }

    @Test func queryTokensKeepRawWordsWithoutStopwords() {
        let t = DedupeText.queryTokens("The role of β-catenin in the developing cortex: a study")
        #expect(t.contains("β") == false)          // one letter: too short
        #expect(t.contains("catenin") && t.contains("developing") && t.contains("cortex") && t.contains("role"))
        #expect(!t.contains("the") && !t.contains("study"))
        #expect(DedupeText.queryTokens(String(repeating: "word ", count: 3) + "uniqueness extraordinarily").count <= 12)
        #expect(DedupeText.queryTokens("Hsp70 in 3D").contains("hsp70"))
    }

    @Test func prefixContainment() {
        let a = DedupeText.titleNorm("A single-cell atlas of the human retina")
        let b = DedupeText.titleNorm("A single-cell atlas of the human retina: insights into degeneration")
        #expect(DedupeText.prefixContained(a, b) && DedupeText.prefixContained(b, a))
        #expect(!DedupeText.prefixContained(DedupeText.titleNorm("Deep learning"), DedupeText.titleNorm("Deep learning for X and Y")))
        #expect(!DedupeText.prefixContained(a, DedupeText.titleNorm("An atlas of the human retina at single-cell resolution")))
    }
}

@Suite struct VersionRankTests {
    @Test func tiers() {
        #expect(VersionRank.of(ids: PaperIDs(doi: "10.1038/s41586-024-08351-7"), venue: "Nature").tier == .published)
        #expect(VersionRank.of(ids: PaperIDs(doi: "10.1101/2024.01.02.573456"), venue: "bioRxiv").tier == .preprint)
        #expect(VersionRank.of(ids: PaperIDs(doi: "10.1101/gr.277000.122"), venue: nil).tier == .published)
        #expect(VersionRank.of(ids: PaperIDs(arxivID: "2401.01234", arxivVersion: 3), venue: nil) == VersionRank(tier: .preprint, version: 3))
        #expect(VersionRank.of(ids: PaperIDs(doi: "10.5555/x"), venue: nil, workType: "posted-content/preprint").tier == .preprint)
        #expect(VersionRank.of(ids: PaperIDs(), venue: "medRxiv").tier == .preprint)
        #expect(VersionRank.of(ids: PaperIDs(), venue: nil).tier == .unknown)
        #expect(VersionRank.of(ids: PaperIDs(doi: "10.7554/eLife.98765.3"), venue: "eLife") == VersionRank(tier: .published, version: 3))
    }

    @Test func newer() {
        let journal = VersionRank(tier: .published), preprint = VersionRank(tier: .preprint, version: 2)
        #expect(VersionRank.newer(new: journal, existing: preprint) == .new)
        #expect(VersionRank.newer(new: preprint, existing: journal) == .existing)
        #expect(VersionRank.newer(new: VersionRank(tier: .preprint, version: 3), existing: VersionRank(tier: .preprint, version: 1)) == .new)
        #expect(VersionRank.newer(new: VersionRank(tier: .preprint, version: 0), existing: VersionRank(tier: .preprint, version: 1)) == nil)
        #expect(VersionRank.newer(new: journal, existing: VersionRank(tier: .unknown)) == nil)
        #expect(VersionRank(code: VersionRank(tier: .preprint, version: 7).code) == VersionRank(tier: .preprint, version: 7))
    }
}

@Suite struct MinHashTests {
    /// The signature of a fixed input never changes (Swift's `Hasher` is seeded per process —
    /// a stored signature computed with it would never match again).
    @Test func signatureIsStableAcrossLaunches() throws {
        // Golden values, computed independently (FNV-1a 64 + the fixed SplitMix64 seeds): a change
        // here means every stored signature stops matching.
        let sig = try #require(MinHash.signature(MinHash.shingles(MinHash.words("The quick brown fox jumps over the lazy dog again"),
                                                                  size: 3), k: 8))
        #expect(sig == [939787901, 48349588, 526670454, 4995481, 23700134, 42525174, 68934632, 402958801])
        #expect(MinHash.fnv1a("abc") == 0xe71f_a219_0541_574b)
        #expect(MinHash.seeds.count == MinHash.pageSize && Set(MinHash.seeds).count == MinHash.pageSize)
        #expect(MinHash.seeds[0] == 0xd853_6ad4_b39f_92dc)
    }

    @Test func jaccardEstimate() throws {
        let words = (0..<400).map { "w\($0 % 97)x\($0 % 13)" }
        let a = try #require(MinHash.signature(MinHash.shingles(words, size: 4), k: 128))
        var edited = words
        for i in stride(from: 0, to: 400, by: 40) { edited[i] = "changed\(i)" }
        let b = try #require(MinHash.signature(MinHash.shingles(edited, size: 4), k: 128))
        let unrelated = try #require(MinHash.signature(MinHash.shingles((0..<400).map { "z\($0 % 89)" }, size: 4), k: 128))
        let est = try #require(MinHash.jaccard(a, b))
        // True Jaccard: 10 edits break ≤ 40 of 397 shingles → ≈ 0.82.
        #expect(abs(est - 0.82) <= 0.1, "\(est)")
        #expect((MinHash.jaccard(a, unrelated) ?? 1) < 0.15)
        #expect(MinHash.jaccard(a, a) == 1)
        #expect(MinHash.jaccard(a, nil) == nil && MinHash.jaccard(a, Array(a.prefix(10))) == nil)
    }

    @Test func runningHeadersAreDropped() {
        let header = "Journal of Synthetic Results 12 (2026) 1-20"
        let topics = ["cortex neurons", "retina photoreceptors", "kidney nephrons"]
        let pages = (1...3).map { "\(header)\nBody text of page \($0) about \(topics[$0 - 1])\n\($0)" }
        let w = MinHash.bodyWords(pages: pages)
        #expect(!w.contains("synthetic"))
        #expect(w.contains("cortex") && w.contains("nephrons"))
        #expect(w.filter { $0 == "3" }.count == 1)          // the bare page-number line is gone
    }

    @Test func storageRoundTrip() throws {
        let page = (0..<128).map { UInt32($0 * 7919) }, abs = (0..<64).map { UInt32($0 * 31) }
        let data = try #require(MinHash.encode(page: page, abstract: abs, sha256: "0123456789abcdef0123"))
        let back = MinHash.decode(data)
        #expect(back.page == page && back.abstract == abs && back.sha256Prefix == "0123456789abcdef")
        #expect(MinHash.decode(MinHash.encode(page: nil, abstract: abs)).abstract == abs)
        #expect(MinHash.encode(page: nil, abstract: nil) == nil)
        #expect(MinHash.decode(Data("garbage-garbage-garbage".utf8)).page == nil)
    }
}

@Suite struct DupChoiceRuleTests {
    func paper(status: PaperStatus = .toRead, deleted: Bool = false, doi: String? = "10.1101/2024.01.01.000001") -> Paper {
        var p = Paper(pk: 1, sha256: "e", fileSize: 1, ids: PaperIDs(doi: doi), title: "Earlier", folder: "Papers/E",
                      pdfName: "E.pdf", originalName: "e.pdf", status: status)
        if deleted { p.deletedAt = Date() }
        return p
    }

    func review(parked: Bool = true, band: DupBand = .certain, relation: DupRelation = .sameWork, newer: DupSide? = nil,
                history: Bool = false) -> DupReview {
        DupReview(newPaperID: parked ? nil : "n", existingPaperID: history ? nil : "e", band: band, score: 1, createdAt: Date(),
                  newPaperPK: parked ? nil : 2, existingPaperPK: history ? nil : 1, historyPK: history ? 9 : nil,
                  relation: relation, newerSide: newer, pendingID: parked ? "p" : nil)
    }

    @Test func defaultsNeverThrowTheLibrarysVersionAway() {
        let newer = DupChoiceRules.choices(review(relation: .newerVersion, newer: .new), newIDs: PaperIDs(doi: "10.1038/x"),
                                           existing: paper(), history: nil)
        #expect(newer.default == .keepNew && newer.choices.first == .keepNew)
        let doneSame = DupChoiceRules.choices(review(relation: .sameVersion), newIDs: PaperIDs(doi: "10.1101/2024.01.01.000001"),
                                              existing: paper(status: .done), history: nil)
        #expect(doneSame.default == .rereadEarlier)
        // Same DOI and both live: "keep both" is impossible (one live paper per DOI).
        #expect(!doneSame.choices.contains(.keepBoth))
        let older = DupChoiceRules.choices(review(relation: .olderVersion, newer: .existing), newIDs: PaperIDs(doi: "10.1101/2024.01.01.000001"),
                                           existing: paper(doi: "10.1038/y"), history: nil)
        #expect(older.default == .skip && older.choices.contains(.keepBoth))
    }

    @Test func supplementsAttachAndNeverOfferReplaceFirst() {
        let r = DupChoiceRules.choices(review(relation: .supplement), newIDs: PaperIDs(doi: "10.1101/2024.01.01.000001"),
                                       existing: paper(), history: nil)
        #expect(r.default == .attachSupplement && r.choices == [.attachSupplement, .keepBoth, .skip])
        #expect(!r.choices.contains(.keepNew))
    }

    @Test func deletedAndHistory() {
        let deleted = DupChoiceRules.choices(review(), newIDs: PaperIDs(doi: "10.1101/2024.01.01.000001"),
                                             existing: paper(deleted: true), history: nil)
        #expect(deleted.default == .rereadEarlier && deleted.choices.contains(.keepBoth))
        let hist = DupChoiceRules.choices(review(parked: false, band: .likely, history: true), newIDs: PaperIDs(),
                                          existing: nil, history: DupHistoryRow(paperID: "x", sha256: nil, doi: nil, arxivID: nil,
                                                                                publishedDOI: nil, keys: [], title: "t", titleNorm: "t",
                                                                                firstSurname: nil, year: nil, page: nil, abstract: nil,
                                                                                lastStatus: .done, readCount: 1, doneAt: nil,
                                                                                addedAt: nil, purgedAt: Date()))
        #expect(hist.choices == [.addAgain, .skip] && hist.default == .addAgain)
        let possible = DupChoiceRules.choices(review(parked: false, band: .possible), newIDs: PaperIDs(doi: "10.1/a"),
                                              existing: paper(doi: "10.1/b"), history: nil)
        #expect(possible.default == .keepBoth)
    }
}

@Suite struct DupExplainerTests {
    @Test func wordsInBothLanguages() {
        let r = DupReview(newPaperID: nil, existingPaperID: "e", band: .certain, score: 1, createdAt: Date(),
                          relation: .newerVersion, evidence: [DupEvidence(.publishedDOI, value: "10.1038/x"),
                                                              DupEvidence(.title, percent: 98), DupEvidence(.firstAuthor, value: "wang"),
                                                              DupEvidence(.authors, count: 9, total: 11), DupEvidence(.text, percent: 71)])
        let n = DupSideSummary(title: "New", venue: "Nature", year: 2025,
                               versionLabel: DupExplainer.versionLabel(venue: "Nature", rank: VersionRank(tier: .published)))
        let e = DupSideSummary(title: "Old", venue: "bioRxiv", year: 2024,
                               versionLabel: DupExplainer.versionLabel(venue: "bioRxiv", rank: VersionRank(tier: .preprint, version: 2)),
                               status: .done, addedAt: Date(timeIntervalSince1970: 1_772_000_000),
                               doneAt: Date(timeIntervalSince1970: 1_775_000_000), checklistDone: 7, checklistTotal: 7)
        let cal = DedupeKit.calendar
        let en = DupExplainer.explain(r, new: n, existing: e, lang: .en, calendar: cal)
        let zh = DupExplainer.explain(r, new: n, existing: e, lang: .zh, calendar: cal)
        #expect(en.headline == "Same paper, newer version" && zh.headline == "同一篇论文的新版本")
        #expect(en.versionLine == "New: Nature (2025) · In your library: bioRxiv v2 (2024)")
        #expect(en.evidence == ["The preprint's published DOI is 10.1038/x", "Title 98% identical", "Same first author (Wang)",
                                "9 of 11 authors match", "Text overlap about 71%"])
        #expect(zh.evidence.count == 5 && zh.evidence.allSatisfy { !$0.isEmpty } && zh.evidence != en.evidence)
        #expect(en.historyLine?.contains("finished") == true && en.historyLine?.contains("checklist 7/7") == true)
        // Every evidence code and relation has distinct en and zh words.
        for code in DupEvidence.Code.allCases {
            let ev = DupEvidence(code, value: "v", percent: 50, count: 1, total: 2)
            #expect(DupExplainer.line(ev, lang: .en) != DupExplainer.line(ev, lang: .zh), "\(code)")
        }
        for relation in DupRelation.allCases {
            var rr = r
            rr.relation = relation
            #expect(DupExplainer.headline(rr, existing: e, lang: .en) != DupExplainer.headline(rr, existing: e, lang: .zh))
        }
    }

    @Test func classicToastsAreRecognized() {
        let same = Toast(kind: .info, message: "x", buttons: [.init(title: "a", action: .replaceKeepingChecklist(pendingID: "p")),
                                                              .init(title: "b", action: .ignorePending(pendingID: "p"))])
        #expect(DupExplainer.classicSameWorkPendingID(same) == "p")
        let look = Toast(kind: .info, message: "May duplicate a paper already in the library: T",
                         buttons: [.init(title: "View", action: .openPaper(id: "e1"))])
        #expect(DupExplainer.classicLookalikePaperID(look) == "e1")
        #expect(DupExplainer.classicLookalikePaperID(Toast(kind: .info, message: "Added: T",
                                                           buttons: [.init(title: "View", action: .openPaper(id: "e1"))])) == nil)
        let r = DupReview(newPaperID: nil, existingPaperID: "e", band: .certain, score: 1, createdAt: Date(),
                          relation: .supplement, pendingID: "p")
        let t = DupExplainer.reviewToast(r, newTitle: "mmc1.pdf", existingTitle: "Paper", existingIsLive: true, lang: .en)
        #expect(t.buttons.map(\.action) == [.openDuplicateReview(id: r.id), .resolveDuplicate(reviewID: r.id, choice: .skip)])
    }
}
