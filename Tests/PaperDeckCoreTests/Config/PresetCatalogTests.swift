import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

// T4 FieldPresetTests and T7 SenderPresetCatalogTests (PORTABILITY_PLAN §5.4): the field and
// sender catalogs are well-formed data, and the life-sciences field is exactly today's.
@Suite struct FieldPresetTests {
    @Test func elevenFieldsWithUniqueIDs() {
        let ids = FieldPresets.all.map(\.id)
        #expect(ids.count == 11 && Set(ids).count == 11)
        #expect(ids.first == "lifeSciencesCompBio" && ids.last == "general")
        for id in ids { #expect(FieldPresets.preset(id: id)?.id == id) }
        #expect(FieldPresets.preset(id: "nope") == nil && FieldPresets.preset(id: nil) == nil)
    }

    @Test(arguments: FieldPresets.all.map(\.id))
    func everyFieldIsWellFormed(_ id: String) throws {
        let f = try #require(FieldPresets.preset(id: id))
        #expect(f.checklistExamples.count == 4)
        #expect(!f.starterCategories.isEmpty && f.starterCategories.count <= 7)
        #expect(f.starterCategories.allSatisfy { !$0.name.isEmpty && $0.name.count <= 40 && !$0.description.isEmpty })
        #expect(Set(f.starterCategories.map { $0.name.lowercased() }).count == f.starterCategories.count)
        #expect(f.readerPattern.contains("{level}") && f.difficultyPattern.contains("{stage}"))
        #expect(!f.methodHint.isEmpty && !f.typicalTimes.isEmpty && !f.symbol.isEmpty)
        for text in [f.name, f.interestsPlaceholder, f.categoryDescriptionExample, f.categoryPlaceholderExample,
                     f.customInstructionsExample, f.alertsTip] {
            #expect(!text.en.isEmpty && !text.zh.isEmpty, "\(id)")
        }
        // Plain one-line prompt text: nothing a sanitizer would change.
        for slot in [f.methodHint, f.typicalTimes] + f.checklistExamples {
            #expect(CardPromptProfile.sanitize(slot) == slot && !slot.contains("\""), "\(id): \(slot)")
        }
        for stage in CareerStage.allCases {
            let p = f.cardProfile(stage: stage, readerOverride: nil)
            #expect(p.reader.contains(stage.levelPhrase) && p.difficultyReference.contains(stage.stageNoun))
            #expect(!p.reader.contains("{") && !p.difficultyReference.contains("{"))
        }
        // Every suggested sender exists in the catalog.
        for sender in f.senderPresetIDs { #expect(SenderPresetCatalog.entry(id: sender) != nil, "\(id): \(sender)") }
        #expect(f.senderPresetIDs.first == "preset-google-scholar")
    }

    @Test func lifeSciencesIsTodaysField() {
        let f = FieldPresets.lifeSciencesCompBio
        #expect(f.starterCategories == PaperCategory.starters.map { StarterCategory(name: $0.name, description: $0.description) })
        #expect(f.cardProfile(stage: .phd, readerOverride: nil) == .legacyCompBio)
        #expect(f.senderPresetIDs == SenderRule.presets.map(\.id))
    }

    @Test func unknownFieldIDsFallBackByOrigin() {
        #expect(ConfigResolver.field("astrology", origin: .fresh) == FieldPresets.general)
        #expect(ConfigResolver.field("astrology", origin: .legacy) == FieldPresets.lifeSciencesCompBio)
        #expect(ConfigResolver.field(nil, origin: .fresh) == FieldPresets.general)
        #expect(ConfigResolver.field(nil, origin: .legacy) == FieldPresets.lifeSciencesCompBio)
        #expect(ConfigResolver.field("csML", origin: .legacy) == FieldPresets.csML)
    }

    @Test func stagesHaveTheirPhrases() {
        #expect(CareerStage.phd.levelPhrase == "PhD level" && CareerStage.phd.stageNoun == "PhD student")
        #expect(CareerStage.allCases.map(\.rawValue) == ["masters", "phd", "postdoc", "faculty"])
        for s in CareerStage.allCases { #expect(!s.title.en.isEmpty && !s.title.zh.isEmpty) }
    }
}

@Suite struct SenderPresetCatalogTests {
    @Test func theNineLegacyPresetsComeFirstInTodaysOrder() {
        let legacy = Array(SenderPresetCatalog.all.prefix(SenderRule.presets.count))
        #expect(legacy.map(\.rule) == SenderRule.presets)
        #expect(legacy.allSatisfy { $0.verified })
        #expect(SenderPresetCatalog.all.dropFirst(SenderRule.presets.count).allSatisfy { !$0.verified })
        #expect(SenderPresetCatalog.all.count == 27)
    }

    @Test func idsAreUniqueAndEveryPatternParses() {
        let ids = SenderPresetCatalog.all.map(\.rule.id)
        #expect(Set(ids).count == ids.count)
        for e in SenderPresetCatalog.all {
            #expect(SenderMatcher.Pattern(e.rule.pattern) != nil, "\(e.rule.id): \(e.rule.pattern)")
            #expect(e.rule.kind == .alert && e.rule.aiPolicy == .always && e.rule.enabled && !e.rule.autoMerge)
            #expect(!e.rule.label.isEmpty && e.rule.id.hasPrefix("preset-"))
        }
    }

    @Test func suggestedIsTheFieldsVerifiedPresetsAndOthersTheRest() {
        #expect(SenderPresetCatalog.suggested(for: FieldPresets.lifeSciencesCompBio) == SenderRule.presets)
        let cs = FieldPresets.csML
        #expect(SenderPresetCatalog.suggested(for: cs).map(\.id) == ["preset-google-scholar", "preset-arxiv"])
        let others = SenderPresetCatalog.others(for: cs).map(\.id)
        #expect(others.contains("preset-openreview") && others.contains("preset-biorxiv"))
        #expect(!others.contains("preset-arxiv"))
        for f in FieldPresets.all {
            let suggested = Set(SenderPresetCatalog.suggested(for: f).map(\.id))
            let rest = Set(SenderPresetCatalog.others(for: f).map(\.id))
            #expect(suggested.isDisjoint(with: rest) && suggested.union(rest).count == SenderPresetCatalog.all.count)
        }
    }
}
