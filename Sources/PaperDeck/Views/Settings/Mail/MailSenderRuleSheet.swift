import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Add / edit one sender: pattern (validated with `SenderMatcher.Pattern`), kind, AI policy
/// (default by kind: alerts always; people the institution's default — ask, or never — so a
/// preset can only be stricter), and the merge defaults of its papers.
struct MailSenderRuleSheet: View {
    let original: SenderRule?
    let existing: [SenderRule]
    let categories: [String]
    /// The AI policy a new person / advisor rule starts with (`org.peopleDefault`).
    let peopleDefault: PeopleAIDefault
    let onClose: (SenderRule?) -> Void

    @State private var rule: SenderRule
    /// The user picked an AI policy explicitly (a kind change then keeps it).
    @State private var policyTouched: Bool

    init(rule: SenderRule?, existing: [SenderRule], categories: [String],
         peopleDefault: PeopleAIDefault = L.org.peopleDefault, onClose: @escaping (SenderRule?) -> Void) {
        self.original = rule
        self.existing = existing
        self.categories = categories
        self.peopleDefault = peopleDefault
        self.onClose = onClose
        _rule = State(initialValue: rule ?? SenderRule(pattern: "", kind: .person, aiPolicy: peopleDefault.policy))
        _policyTouched = State(initialValue: rule != nil)
    }

    private var pattern: SenderMatcher.Pattern? { SenderMatcher.Pattern(rule.pattern) }

    /// Another rule with the same (normalized) pattern.
    private var duplicate: SenderRule? {
        guard let p = pattern else { return nil }
        return existing.first { $0.id != rule.id && SenderMatcher.Pattern($0.pattern) == p }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(original == nil ? L.MailPref.addSenderTitle : L.MailPref.editSenderTitle).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Form {
                senderSection
                kindSection
                aiSection
                mergeSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L.cancel, role: .cancel) { onClose(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? L.MailPref.addSenderButton : L.Pref.save) { onClose(normalized()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pattern == nil || duplicate != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 680)
    }

    // MARK: Sections

    private var senderSection: some View {
        Section {
            TextField(L.MailPref.pattern, text: $rule.pattern, prompt: Text(L.MailPref.patternPrompt))
                .autocorrectionDisabled()
            validation
            TextField(L.MailPref.senderLabel, text: $rule.label, prompt: Text(L.MailPref.senderLabelPrompt))
        } header: {
            Text(L.MailPref.senderSection)
        } footer: {
            NoteText(L.MailPref.patternFooter)
        }
    }

    @ViewBuilder
    private var validation: some View {
        if rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
            StatusLine(.pending, L.MailPref.patternEmpty)
        } else if let p = pattern {
            if let d = duplicate {
                StatusLine(.warning, L.MailPref.patternDuplicate(d.label.isEmpty ? d.pattern : d.label))
            } else {
                StatusLine(.ok, L.MailPref.patternMeaning(p))
            }
        } else {
            StatusLine(.error, L.MailPref.patternInvalid)
        }
    }

    private var kindSection: some View {
        Section {
            Picker(L.MailPref.kind, selection: kindBinding) {
                ForEach([SenderKind.advisor, .person, .alert], id: \.self) { Text(L.MailPref.kindName($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            NoteText(L.MailPref.kindHint(rule.kind))
        }
    }

    private var aiSection: some View {
        Section {
            Picker(L.MailPref.aiPolicy, selection: policyBinding) {
                ForEach(MailAIPolicy.allCases, id: \.self) { Text(L.MailPref.aiPolicyName($0)).tag($0) }
            }
            .pickerStyle(.radioGroup)
            NoteText(L.MailPref.aiPolicyHint(rule.aiPolicy))
            if rule.kind != .alert, rule.aiPolicy == .always {
                StatusLine(.warning, L.MailPref.personSenderWarning)
            }
        } header: {
            HStack(spacing: 6) {
                Text(L.MailPref.aiSection)
                HelpButton(.mailSendersAndAI)
            }
        } footer: {
            if rule.kind != .alert { NoteText(L.MailPref.policyNote, symbol: "building.columns") }
        }
    }

    private var mergeSection: some View {
        Section {
            Picker(L.MailPref.defaultPriority, selection: $rule.defaultPriority) {
                Text(L.MailPref.priorityByKind(rule.kind)).tag(Priority?.none)
                Text(L.MailPref.priorityName(.high)).tag(Priority?.some(.high))
                Text(L.MailPref.priorityName(.normal)).tag(Priority?.some(.normal))
                Text(L.MailPref.priorityName(.low)).tag(Priority?.some(.low))
            }
            Picker(L.MailPref.defaultCategory, selection: categoryBinding) {
                Text(L.MailPref.noCategory).tag("")
                ForEach(categoryChoices, id: \.self) { Text($0).tag($0) }
            }
            Toggle(isOn: $rule.useDueDateAsDDL) {
                Text(L.MailPref.useDueDate)
                Text(L.MailPref.useDueDateHint)
            }
            Toggle(isOn: $rule.autoMerge) {
                Text(L.MailPref.autoMerge)
                Text(L.MailPref.autoMergeHint)
            }
            Toggle(isOn: $rule.autoDownload) {
                Text(L.MailPref.autoDownload)
                Text(L.MailPref.autoDownloadHint)
            }
        } header: {
            Text(L.MailPref.mergeDefaultsSection)
        }
    }

    // MARK: Bindings

    private var kindBinding: Binding<SenderKind> {
        Binding {
            rule.kind
        } set: { k in
            guard k != rule.kind else { return }
            rule.kind = k
            if !policyTouched { rule.aiPolicy = k == .alert ? .always : peopleDefault.policy }
        }
    }

    private var policyBinding: Binding<MailAIPolicy> {
        Binding {
            rule.aiPolicy
        } set: { p in
            rule.aiPolicy = p
            policyTouched = true
        }
    }

    private var categoryBinding: Binding<String> {
        Binding { rule.defaultCategory ?? "" } set: { rule.defaultCategory = $0.isEmpty ? nil : $0 }
    }

    /// Library categories plus a rule's category that no longer exists (kept, shown as is).
    private var categoryChoices: [String] {
        var out = categories
        if let c = rule.defaultCategory, !c.isEmpty, !out.contains(c) { out.append(c) }
        return out
    }

    /// The canonical pattern (`name@x.edu`, `@x.org`, `@*.x.com`), a trimmed label.
    private func normalized() -> SenderRule {
        var r = rule
        switch pattern {
        case .address(let a)?: r.pattern = a
        case .domain(let d)?: r.pattern = "@" + d
        case .wildcard(let d)?: r.pattern = "@*." + d
        case nil: break
        }
        r.label = r.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return r
    }
}
