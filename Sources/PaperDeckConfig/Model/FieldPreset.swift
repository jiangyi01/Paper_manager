import Foundation
import PaperDeckCore

/// A research field: the reading-card reader, starter categories, suggested alert senders and the
/// example texts of the field-dependent strings (PORTABILITY_PLAN §2.4, §2.7).
package struct FieldPreset: Sendable, Equatable, Identifiable {
    package var id: String
    package var name: LocalizedText
    package var symbol: String                      // SF Symbol of the field card
    /// "a computational-biology researcher ({level})" — `{level}` = `CareerStage.levelPhrase`.
    package var readerPattern: String
    /// "a comp-bio {stage}" — `{stage}` = `CareerStage.stageNoun`.
    package var difficultyPattern: String
    package var methodHint: String
    package var typicalTimes: String
    package var checklistExamples: [String]         // exactly 4
    package var starterCategories: [StarterCategory]    // at most 7
    package var senderPresetIDs: [String]           // into SenderPresetCatalog, in menu order
    /// Research-interests placeholder (never written as a value).
    package var interestsPlaceholder: LocalizedText
    /// Bare example of a category description (Settings ▸ Library ▸ Edit Description… hint);
    /// `FieldStrings.describeHint` adds "e.g. ".
    package var categoryDescriptionExample: LocalizedText
    /// Bare example of the sidebar's category description field;
    /// `FieldStrings.categoryDescriptionPlaceholder` adds "e.g. ". (Today's two texts differ.)
    package var categoryPlaceholderExample: LocalizedText
    /// Bare example of "Instructions for the AI" (`FieldStrings.customInstructionsHint`).
    package var customInstructionsExample: LocalizedText
    /// The whole alerts tip of the IMAP forms.
    package var alertsTip: LocalizedText

    package init(id: String, name: LocalizedText, symbol: String, readerPattern: String, difficultyPattern: String,
                 methodHint: String, typicalTimes: String, checklistExamples: [String],
                 starterCategories: [StarterCategory], senderPresetIDs: [String], interestsPlaceholder: LocalizedText,
                 categoryDescriptionExample: LocalizedText, categoryPlaceholderExample: LocalizedText,
                 customInstructionsExample: LocalizedText, alertsTip: LocalizedText) {
        self.id = id; self.name = name; self.symbol = symbol; self.readerPattern = readerPattern
        self.difficultyPattern = difficultyPattern; self.methodHint = methodHint; self.typicalTimes = typicalTimes
        self.checklistExamples = checklistExamples; self.starterCategories = starterCategories
        self.senderPresetIDs = senderPresetIDs; self.interestsPlaceholder = interestsPlaceholder
        self.categoryDescriptionExample = categoryDescriptionExample
        self.categoryPlaceholderExample = categoryPlaceholderExample
        self.customInstructionsExample = customInstructionsExample; self.alertsTip = alertsTip
    }

    /// The reading-card profile for `stage`. A user-written reader (sanitized) replaces the
    /// composed one, and difficulty is then relative to "the reader described above".
    package func cardProfile(stage: CareerStage, readerOverride: String?) -> CardPromptProfile {
        if let reader = readerOverride.flatMap(CardPromptProfile.sanitize) {
            return CardPromptProfile(reader: reader, difficultyReference: "the reader described above",
                                     methodHint: methodHint, typicalTimes: typicalTimes,
                                     checklistExamples: checklistExamples)
        }
        return CardPromptProfile(reader: readerPattern.replacingOccurrences(of: "{level}", with: stage.levelPhrase),
                                 difficultyReference: difficultyPattern.replacingOccurrences(of: "{stage}", with: stage.stageNoun),
                                 methodHint: methodHint, typicalTimes: typicalTimes,
                                 checklistExamples: checklistExamples)
    }
}
