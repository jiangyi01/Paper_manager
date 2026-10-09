import Foundation
import Testing
@testable import PaperDeckCore

/// Foundation also exports the ObjC runtime's `PaperCategory` typedef.

@Suite struct TaxonomyTests {
    private static let starters: [PaperCategory] = PaperCategory.starters.enumerated().map { index, s in
        PaperCategory(pk: Int64(index + 1), name: s.name, description: s.description, hue: index, origin: .starter)
    }

    private static func manyCategories(_ n: Int) -> [PaperCategory] {
        (1...n).map { PaperCategory(pk: Int64($0), name: "Topic \($0)", description: nil, hue: $0 % 10, origin: .agent) }
    }

    private static func decide(_ category: String, new: ReadingCard.NewCategory? = nil, tags: [String] = [],
                               existing: [PaperCategory] = starters, profiles: [Taxonomy.CategoryProfile] = [],
                               allowNew: Bool = true, userSet: Bool = false,
                               current: Int64? = nil) -> Taxonomy.Decision {
        Taxonomy.decide(category: category, newCategory: new, tags: tags, existing: existing, profiles: profiles,
                        allowNew: allowNew, categoryUserSet: userSet, currentPK: current)
    }

    // MARK: decide

    @Test func userSetCategoryIsNeverTouched() {
        #expect(Self.decide("Single-cell & Spatial Omics", userSet: true, current: 5) == .keep)
        #expect(Self.decide("__new__", new: .init(name: "Plant Biology", description: "x"), userSet: true) == .keep)
    }

    @Test func existingNameMatchesCaseInsensitively() {
        #expect(Self.decide("Single-cell & Spatial Omics") == .useExisting(pk: 3))
        #expect(Self.decide("  single-cell &  spatial omics ") == .useExisting(pk: 3))
        // Still honoured when the library is full or new categories are off.
        #expect(Self.decide("topic 7", existing: Self.manyCategories(25), allowNew: false) == .useExisting(pk: 7))
    }

    @Test func newCategoryIsCreatedWithNormalizedNameAndFreeHue() {
        let decision = Self.decide("__new__", new: .init(name: "  plant stress\nphysiology and signalling ",
                                                          description: "Plants under\tstress."))
        // Starters use hues 0…6 → first unused slot is 7.
        #expect(decision == .createNew(name: "Plant Stress Physiology", description: "Plants under stress.", hue: 7))
    }

    @Test func newCategoryCollidingWithExistingReusesIt() {
        #expect(Self.decide("__new__", new: .init(name: "neuroscience & development", description: "")) == .useExisting(pk: 5))
        // Collision after normalization (Title Case, whitespace).
        let lib = Self.starters + [PaperCategory(pk: 99, name: "Plant Biology", hue: 8, origin: .agent)]
        #expect(Self.decide("__new__", new: .init(name: "plant   biology", description: ""), existing: lib) == .useExisting(pk: 99))
        // Explicit name of an existing category wins even when creation is disabled.
        #expect(Self.decide("__new__", new: .init(name: "PLANT BIOLOGY", description: ""), existing: lib,
                            allowNew: false) == .useExisting(pk: 99))
    }

    @Test func unknownNameIsTreatedLikeNew() {
        #expect(Self.decide("Immunology", tags: ["t-cells"]) == .createNew(name: "Immunology", description: "", hue: 7))
        #expect(Self.decide("", new: .init(name: "Immunology", description: "Immune system"))
                == .createNew(name: "Immunology", description: "Immune system", hue: 7))
    }

    @Test func creationDisabledFallsBackToHighestTagOverlap() {
        let profiles = [
            Taxonomy.CategoryProfile(pk: 2, paperCount: 9, tags: ["foundation-model", "transformer"]),
            Taxonomy.CategoryProfile(pk: 3, paperCount: 4, tags: ["single-cell", "spatial-transcriptomics", "atlas"]),
        ]
        let d = Self.decide("__new__", new: .init(name: "Spatial Atlases", description: ""),
                            tags: ["Spatial Transcriptomics", "atlas", "transformer"], profiles: profiles, allowNew: false)
        #expect(d == .fallback(pk: 3, needsReview: true))
    }

    @Test func fullLibraryFallsBackEvenWhenAllowed() {
        let lib = Self.manyCategories(20)
        let profiles = [Taxonomy.CategoryProfile(pk: 12, paperCount: 1, tags: ["crispr"])]
        #expect(Self.decide("__new__", new: .init(name: "Gene Editing", description: ""), tags: ["crispr"],
                            existing: lib, profiles: profiles) == .fallback(pk: 12, needsReview: true))
        // 19 categories still allow one more.
        #expect(Self.decide("__new__", new: .init(name: "Gene Editing", description: ""),
                            existing: Self.manyCategories(19)) == .createNew(name: "Gene Editing", description: "", hue: 0))
    }

    @Test func overlapTiesGoToMostPapersThenName() {
        let lib = [PaperCategory(pk: 1, name: "Zeta", hue: 0, origin: .user),
                   PaperCategory(pk: 2, name: "alpha", hue: 1, origin: .user),
                   PaperCategory(pk: 3, name: "Beta", hue: 2, origin: .user)]
        let busy = [Taxonomy.CategoryProfile(pk: 1, paperCount: 10, tags: ["x-ray"]),
                    Taxonomy.CategoryProfile(pk: 2, paperCount: 3, tags: ["x-ray"]),
                    Taxonomy.CategoryProfile(pk: 3, paperCount: 3, tags: ["x-ray"])]
        #expect(Self.decide("__new__", tags: ["x-ray"], existing: lib, profiles: busy, allowNew: false)
                == .fallback(pk: 1, needsReview: true))
        let even = busy.map { Taxonomy.CategoryProfile(pk: $0.pk, paperCount: 3, tags: $0.tags) }
        #expect(Self.decide("__new__", tags: ["x-ray"], existing: lib, profiles: even, allowNew: false)
                == .fallback(pk: 2, needsReview: true))
        // No profiles at all → most papers is a tie too → name order.
        #expect(Self.decide("__new__", existing: lib, allowNew: false) == .fallback(pk: 2, needsReview: true))
    }

    @Test func overlapTieKeepsTheCurrentCategory() {
        let lib = [PaperCategory(pk: 1, name: "Alpha", hue: 0, origin: .user), PaperCategory(pk: 2, name: "Beta", hue: 1, origin: .user)]
        let profiles = [Taxonomy.CategoryProfile(pk: 1, paperCount: 5, tags: ["rna"]),
                        Taxonomy.CategoryProfile(pk: 2, paperCount: 1, tags: ["rna"])]
        #expect(Self.decide("__new__", tags: ["rna"], existing: lib, profiles: profiles, allowNew: false, current: 2)
                == .fallback(pk: 2, needsReview: true))
    }

    @Test func keywordOverlapBreaksTiesInAnUntaggedLibrary() {
        // Fresh library: starters have no tagged papers yet, creation disabled.
        let d = Self.decide("__new__", new: .init(name: "Spatial Transcriptomics", description: ""),
                            tags: ["visium", "cell-segmentation"], allowNew: false)
        #expect(d == .fallback(pk: 3, needsReview: true))
    }

    @Test func noCategoriesAndNoCreationKeeps() {
        #expect(Self.decide("__new__", new: .init(name: "Anything", description: ""), existing: [], allowNew: false) == .keep)
        // Creation allowed but nothing to name it → nothing to fall back to either.
        #expect(Self.decide("__new__", existing: [], allowNew: true) == .keep)
        #expect(Self.decide("__new__", new: .init(name: " & — ", description: ""), existing: [], allowNew: true) == .keep)
        #expect(Self.decide("__new__", new: .init(name: "__NEW__", description: ""), existing: [], allowNew: true) == .keep)
    }

    @Test func newTokenWithoutNameFallsBackWhenCategoriesExist() {
        #expect(Self.decide("__new__", tags: ["single-cell"],
                            profiles: [.init(pk: 3, paperCount: 2, tags: ["single-cell"])]) == .fallback(pk: 3, needsReview: true))
    }

    @Test func cardOverloadUsesCardFields() {
        let card = ReadingCard(tldr: "t", summary: "s", contributions: [], method: "m", results: [], limitations: [],
                               keyTerms: [], resources: [], paperType: .research, category: "__new__",
                               newCategory: .init(name: "cryo-EM methods", description: "Cryo-EM."),
                               tags: ["cryo-em"], difficulty: .medium, estimatedMinutes: 60, checklist: [],
                               textQuality: .good)
        #expect(Taxonomy.decide(card: card, existing: Self.starters, profiles: [], allowNew: true,
                                categoryUserSet: false, currentPK: nil)
                == .createNew(name: "Cryo-EM Methods", description: "Cryo-EM.", hue: 7))
    }

    // MARK: names

    @Test func categoryNameNormalization() {
        #expect(Taxonomy.normalizeCategoryName("single-cell omics") == "Single-cell Omics")
        #expect(Taxonomy.normalizeCategoryName("tools for cell biology research") == "Tools for Cell Biology")
        #expect(Taxonomy.normalizeCategoryName("Spatial Transcriptomics & Imaging Methods") == "Spatial Transcriptomics & Imaging")
        #expect(Taxonomy.normalizeCategoryName("ML and scRNA-seq") == "ML and scRNA-seq")
        #expect(Taxonomy.normalizeCategoryName("the microbiome of the gut") == "The Microbiome of the Gut")
        #expect(Taxonomy.normalizeCategoryName("\"Plant Biology.\"") == "Plant Biology")
        #expect(Taxonomy.normalizeCategoryName("Evolution and") == "Evolution")
        #expect(Taxonomy.normalizeCategoryName("Bio\u{202E}logy\u{0007}") == "Biology")
        #expect(Taxonomy.normalizeCategoryName("   ") == nil)
        #expect(Taxonomy.normalizeCategoryName("and of the") == nil)
        let long = Taxonomy.normalizeCategoryName(String(repeating: "x", count: 100) + " biology")
        #expect(long.map { $0.count <= 60 } == true)
    }

    // MARK: hue

    @Test func nextHuePicksTheLeastUsedSlot() {
        #expect(Taxonomy.nextHue(existing: []) == 0)
        #expect(Taxonomy.nextHue(existing: Self.starters) == 7)
        let full = Self.manyCategories(10)                       // hues 1…9, 0 → every slot once
        #expect(Taxonomy.nextHue(existing: full) == 0)
        let skewed = full + [PaperCategory(pk: 50, name: "x", hue: 0, origin: .user), PaperCategory(pk: 51, name: "y", hue: 1, origin: .user)]
        #expect(Taxonomy.nextHue(existing: skewed) == 2)
        #expect(Taxonomy.nextHue(existing: [PaperCategory(name: "odd", hue: -3, origin: .user)]) == 0)
        #expect(Taxonomy.nextHue(existing: [PaperCategory(name: "odd", hue: 10, origin: .user)]) == 1)
    }

    // MARK: tags

    @Test func tagNormalization() {
        #expect(Taxonomy.normalizeTag("Single Cell") == "single-cell")
        #expect(Taxonomy.normalizeTag("scRNA-seq") == "scrna-seq")
        #expect(Taxonomy.normalizeTag("#CRISPR") == "crispr")
        #expect(Taxonomy.normalizeTag("  --Graph__Neural  Networks--  ") == "graph-neural-networks")
        #expect(Taxonomy.normalizeTag("Protéine") == "proteine")
        #expect(Taxonomy.normalizeTag("x") == nil)
        #expect(Taxonomy.normalizeTag("!!!") == nil)
        #expect(Taxonomy.normalizeTag("单细胞") == nil)
        let long = Taxonomy.normalizeTag(String(repeating: "ab-", count: 30))
        #expect(long?.count ?? 0 <= 40)
        #expect(long?.hasSuffix("-") == false)
        for raw in ["Single Cell", "scRNA-seq", String(repeating: "ab-", count: 30), "3D genome"] {
            let tag = Taxonomy.normalizeTag(raw) ?? ""
            #expect(tag.wholeMatch(of: /[a-z0-9][a-z0-9-]{1,39}/) != nil, "\(raw) → \(tag)")
        }
    }

    @Test func tagMerge() {
        let user = [Tag(name: "to-present", origin: .user), Tag(name: "Single Cell", origin: .user)]
        let agent = ["single-cell", "Spatial Omics", "atlas", "neocortex", "atlas", "x", "human", "development",
                     "radial-glia", "brain"]
        let merged = Taxonomy.mergeTags(user: user, agent: agent, suppressed: ["neocortex"])
        #expect(merged.filter { $0.origin == .user }.map(\.name) == ["to-present", "Single Cell"])
        // "single-cell" duplicates a user tag, "atlas" repeats, "x" is invalid, "neocortex" is suppressed.
        #expect(merged.filter { $0.origin == .agent }.map(\.name)
                == ["spatial-omics", "atlas", "human", "development", "radial-glia", "brain"])
        #expect(merged.filter { $0.origin == .agent }.count <= Taxonomy.maxAgentTags)
        #expect(!merged.contains { $0.origin == .suppressed })
    }

    @Test func tagMergeCapsAgentTagsAtSix() {
        let merged = Taxonomy.mergeTags(user: [], agent: (1...10).map { "tag-\($0)" }, suppressed: [])
        #expect(merged.map(\.name) == (1...6).map { "tag-\($0)" })
    }

    @Test func suppressedMatchingIsNormalized() {
        let merged = Taxonomy.mergeTags(user: [], agent: ["Deep Learning", "rna"], suppressed: ["deep-learning"])
        #expect(merged.map(\.name) == ["rna"])
    }
}
