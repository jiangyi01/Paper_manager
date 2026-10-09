import SwiftUI
import PaperDeckCore

/// Settings ▸ Mail ▸ What counts as a reading request (`ReadingCriteria`): used by the local
/// rules at capture and sent to the AI triage as the user's own preferences.
struct MailReadingCriteriaSection: View {
    @Bindable var settings: SettingsStore

    static let kinds: [MailRequestKind] = [.advisorRequest, .journalClub, .fyi, .alertDigest, .other]

    var body: some View {
        Section {
            LabeledContent {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.kinds, id: \.self) { kind in
                        Toggle(L.MailPref.requestKindName(kind), isOn: kindBinding(kind))
                            .toggleStyle(.checkbox)
                    }
                }
            } label: {
                Text(L.MailPref.keepKinds)
                Text(L.MailPref.keepKindsHint)
            }
            LabeledContent {
                MailKeywordField(words: $settings.mailCriteria.includeKeywords, prompt: L.MailPref.includePrompt)
                    .frame(maxWidth: 330)
            } label: {
                Text(L.MailPref.includeKeywords)
                Text(L.MailPref.includeKeywordsHint)
            }
            LabeledContent {
                MailKeywordField(words: $settings.mailCriteria.excludeKeywords, prompt: L.MailPref.excludePrompt)
                    .frame(maxWidth: 330)
            } label: {
                Text(L.MailPref.excludeKeywords)
                Text(L.MailPref.excludeKeywordsHint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L.MailPref.researchInterests)
                Text(L.MailPref.researchInterestsHint).font(.caption).foregroundStyle(.secondary)
                MailTextBox(text: $settings.mailCriteria.researchInterests, height: 48)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L.MailPref.customInstructions)
                Text(L.MailPref.customInstructionsHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MailTextBox(text: $settings.mailCriteria.customInstructions, height: 60)
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: $settings.mailCriteria.minConfidence, in: 0.1...0.9, step: 0.05)
                        .frame(maxWidth: 220)
                    Text(L.MailPref.percent(settings.mailCriteria.minConfidence))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            } label: {
                Text(L.MailPref.minConfidence)
                Text(L.MailPref.minConfidenceHint)
            }
            Stepper(value: $settings.mailCriteria.maxAlertPapers, in: 1...30) {
                Text(L.MailPref.maxAlertPapers(settings.mailCriteria.maxAlertPapers))
                Text(L.MailPref.maxAlertPapersHint)
            }
            Picker(selection: $settings.mailDateOrder) {
                ForEach(SlashDateOrder.allCases, id: \.self) { Text(L.MailPref.dateOrderName($0)).tag($0) }
            } label: {
                Text(L.MailPref.dateOrder)
                Text(L.MailPref.dateOrderHint)
            }
        } header: {
            Text(L.MailPref.criteriaSection)
        } footer: {
            NoteText(L.MailPref.criteriaFooter)
        }
    }

    private func kindBinding(_ kind: MailRequestKind) -> Binding<Bool> {
        Binding {
            settings.mailCriteria.keepKinds.contains(kind)
        } set: { on in
            var kinds = settings.mailCriteria.keepKinds
            if on { kinds.insert(kind) } else { kinds.remove(kind) }
            if kinds != settings.mailCriteria.keepKinds { settings.mailCriteria.keepKinds = kinds }
        }
    }
}
