import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Settings ▸ Mail ▸ Senders — the allowlist. Only mail from these senders is ever opened;
/// every row carries its kind, AI policy and merge defaults (edited in `MailSenderRuleSheet`).
struct MailSenderRulesEditor: View {
    let state: AppState
    @Binding var sheet: MailSettingsSheet?
    @State private var deleting: SenderRule?

    var body: some View {
        let settings = state.settings
        Section {
            if settings.mailSenders.isEmpty {
                NoteText(L.MailPref.noSenders, symbol: "person.crop.circle.badge.questionmark")
            } else {
                header
            }
            ForEach(settings.mailSenders) { rule in
                MailSenderRow(rule: rule, enabled: enabledBinding(rule.id),
                              onEdit: { sheet = .sender(rule) }, onDelete: { deleting = rule })
            }
            HStack(spacing: 10) {
                Button(L.MailPref.addSender) { sheet = .sender(nil) }
                Menu(L.MailPref.addPreset) { presetMenu(settings) }
                    .fixedSize()
                Spacer()
            }
        } header: {
            Text(L.MailPref.sendersSection)
        } footer: {
            NoteText(L.MailPref.sendersFooter, symbol: "hand.raised")
        }
        .alert(L.MailPref.deleteSenderTitle(deleting.map { $0.label.isEmpty ? $0.pattern : $0.label } ?? ""),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L.Pref.delete, role: .destructive) {
                if let r = deleting { settings.removeSender(id: r.id) }
                deleting = nil
            }
            Button(L.cancel, role: .cancel) { deleting = nil }
        } message: {
            Text(L.MailPref.deleteSenderBody)
        }
    }

    /// The research field's suggested alert senders first (for life sciences: today's nine, in
    /// today's order), then "More presets ▸". Presets whose address hasn't been checked against a
    /// real alert say so. Presets already in the list are left out.
    @ViewBuilder
    private func presetMenu(_ settings: SettingsStore) -> some View {
        let menu = Self.presetMenu(field: L.field, existing: settings.mailSenders)
        if menu.suggested.isEmpty && menu.others.isEmpty {
            Text(L.MailPref.allPresetsAdded)
        }
        if !menu.suggested.isEmpty {
            Section(L.MailPref.suggestedFor(L.field.name(L.lang))) {
                ForEach(menu.suggested, id: \.rule.id) { entry in presetButton(entry, settings) }
            }
        }
        if !menu.others.isEmpty {
            Menu(L.MailPref.morePresets) {
                if menu.others.contains(where: { !$0.verified }) {
                    Text(L.MailPref.checkPresetAddress)
                }
                ForEach(menu.others, id: \.rule.id) { entry in presetButton(entry, settings) }
            }
        }
    }

    private func presetButton(_ entry: SenderPresetEntry, _ settings: SettingsStore) -> some View {
        let label = entry.verified ? entry.rule.label : L.MailPref.presetUnverified(entry.rule.label)
        return Button("\(label)  ·  \(entry.rule.pattern)") { settings.upsertSender(entry.rule) }
    }

    /// The preset menu's two parts for `field`, without the patterns `existing` already has.
    static func presetMenu(field: FieldPreset, existing: [SenderRule])
        -> (suggested: [SenderPresetEntry], others: [SenderPresetEntry]) {
        let have = existing.compactMap { SenderMatcher.Pattern($0.pattern) }
        func fresh(_ rule: SenderRule) -> Bool { SenderMatcher.Pattern(rule.pattern).map { !have.contains($0) } ?? false }
        func entry(_ rule: SenderRule) -> SenderPresetEntry {
            SenderPresetCatalog.all.first { $0.rule.id == rule.id } ?? SenderPresetEntry(rule: rule, verified: true)
        }
        return (SenderPresetCatalog.suggested(for: field).filter(fresh).map(entry),
                SenderPresetCatalog.others(for: field).filter(fresh).map(entry))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L.MailPref.colSender).frame(maxWidth: .infinity, alignment: .leading)
            Text(L.MailPref.colKind).frame(width: 78, alignment: .leading)
            Text(L.MailPref.colAI).frame(width: 96, alignment: .leading)
            Color.clear.frame(width: 52, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 26)
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        let settings = state.settings
        return Binding {
            settings.mailSenders.first { $0.id == id }?.enabled ?? false
        } set: { on in
            guard let i = settings.mailSenders.firstIndex(where: { $0.id == id }),
                  settings.mailSenders[i].enabled != on else { return }
            settings.mailSenders[i].enabled = on
        }
    }
}

private struct MailSenderRow: View {
    let rule: SenderRule
    @Binding var enabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(L.MailPref.senderEnabled, isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.label.isEmpty ? rule.pattern : rule.label)
                    .lineLimit(1)
                if !rule.label.isEmpty {
                    Text(rule.pattern)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if SenderMatcher.Pattern(rule.pattern) == nil {
                    Text(L.MailPref.patternInvalidShort).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(enabled ? 1 : 0.55)
            MailSenderKindBadge(kind: rule.kind).frame(width: 78, alignment: .leading)
            Label(L.MailPref.aiPolicyShort(rule.aiPolicy), systemImage: symbol)
                .font(.caption)
                .foregroundStyle(rule.aiPolicy == .never ? .secondary : .primary)
                .frame(width: 96, alignment: .leading)
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help(L.MailPref.edit)
                .accessibilityLabel(L.MailPref.edit)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(L.Pref.delete)
                .accessibilityLabel(L.Pref.delete)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    private var symbol: String {
        switch rule.aiPolicy {
        case .ask: "hand.raised"
        case .always: "sparkles"
        case .never: "nosign"
        }
    }
}
