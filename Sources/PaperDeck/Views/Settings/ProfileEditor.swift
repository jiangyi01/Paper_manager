import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Where the profile editor is embedded.
enum ProfileEditorContext {
    case settings, onboarding
}

/// Field, stage, reader description, research interests and institution policy (Settings ▸
/// Profile and the onboarding "About you" page). Sections for a grouped `Form`; every edit is
/// written at once through `ConfigStore` (`profile.*`, `org.*`) and `SettingsStore`
/// (`mail.criteria.researchInterests`, the single home of research interests).
///
/// The institution changes wording only: the preview shows the sentences people's mail gets.
/// Safety floors (AI off until turned on, people's mail asks first) are code, not settings.
struct ProfileEditor: View {
    let settings: SettingsStore
    let context: ProfileEditorContext

    @State private var readerDraft = ""
    @State private var showPrompt = false
    @State private var customName = ""
    @State private var customShort = ""
    @State private var customTools = ""
    @State private var customURL = ""
    @State private var customPeople: PeopleAIDefault = .ask
    @State private var loaded = false

    init(settings: SettingsStore, context: ProfileEditorContext) {
        self.settings = settings
        self.context = context
    }

    private var config: ConfigStore { settings.config }

    var body: some View {
        Group {
            youSection
            institutionSection
        }
        .onAppear { load() }
    }

    // MARK: You

    private var youSection: some View {
        Section {
            if context == .onboarding {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.Profile.field)
                    fieldGrid
                }
            } else {
                Picker(L.Profile.field, selection: fieldBinding) {
                    ForEach(FieldPresets.all) { f in
                        Label(f.name(L.lang), systemImage: f.symbol).tag(f.id)
                    }
                }
            }
            Picker(L.Profile.stage, selection: stageBinding) {
                ForEach(CareerStage.allCases, id: \.self) { Text($0.title(L.lang)).tag($0) }
            }
            .pickerStyle(.segmented)
            readerEditor
            interestsEditor
        } header: {
            Text(context == .onboarding ? L.Profile.onboardingIntro : L.Profile.youSection)
        } footer: {
            NoteText(L.Profile.fieldNote, symbol: "info.circle")
        }
    }

    /// Onboarding: one card per field.
    private var fieldGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(FieldPresets.all) { f in
                let selected = config.fieldID == f.id
                Button {
                    fieldBinding.wrappedValue = f.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: f.symbol).frame(width: 18)
                        Text(f.name(L.lang))
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private var readerEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L.Profile.reader)
                Spacer()
                Text(L.Profile.readerCount(readerDraft.count, CardPromptProfile.maxReaderLength))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(readerDraft.count >= CardPromptProfile.maxReaderLength ? .orange : .secondary)
                Button(L.Profile.resetToDefault) { commitReader("") }
                    .controlSize(.small)
                    .disabled(readerDraft.isEmpty)
            }
            TextField(L.Profile.reader, text: Binding(get: { readerDraft }, set: { commitReader($0) }),
                      prompt: Text(config.composedReader))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Text(L.Profile.readerHint).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L.Profile.showInstructions, isExpanded: $showPrompt) {
                ScrollView {
                    Text(CardSchema.systemPrompt(for: config.snapshot.cardPromptProfile))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.fill.quaternary))
            }
            .font(.callout)
        }
    }

    private var interestsEditor: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 4) {
            Text(L.Profile.interests)
            TextField(L.Profile.interests, text: $settings.mailCriteria.researchInterests,
                      prompt: Text(config.field.interestsPlaceholder(L.lang)), axis: .vertical)
                .labelsHidden()
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Text(L.Profile.interestsHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Institution

    private var institutionSection: some View {
        let org = config.organization
        return Section {
            Picker(L.Profile.institution, selection: organizationBinding) {
                Text(L.Profile.noPolicy).tag(OrganizationPresets.generic.id)
                ForEach(OrganizationPresets.builtIn.filter { $0.id != OrganizationPresets.generic.id }) { o in
                    Text(L.Profile.presetTitle(name: o.name.map { $0(L.lang) } ?? o.id, short: o.shortName)).tag(o.id)
                }
                Text(L.Profile.other).tag(Self.customID)
            }
            if config.organizationID == Self.customID { customEditor }
            if let note = OrgStrings.legacyNote(org: org, origin: config.origin, lang: L.lang) {
                NoteText(note, symbol: "clock.arrow.circlepath")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L.Profile.previewIntro).font(.callout).foregroundStyle(.secondary)
                StatusLine(.warning, OrgStrings.text(.personSenderWarning, org: org, lang: L.lang))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                NoteText(OrgStrings.text(.policyNote, org: org, lang: L.lang), symbol: "building.columns")
            }
            .padding(.vertical, 2)
        } header: {
            HStack(spacing: 6) {
                Text(L.Profile.institutionSection)
                HelpButton(.profileFieldInstitution)
            }
        } footer: {
            NoteText(L.Profile.institutionFooter, symbol: "lock.shield")
        }
    }

    private var customEditor: some View {
        Group {
            TextField(L.Profile.customName, text: customBinding($customName))
            TextField(L.Profile.customShort, text: customBinding($customShort))
            TextField(L.Profile.customTools, text: customBinding($customTools), prompt: Text(L.Profile.customToolsPrompt))
            TextField(L.Profile.customPolicyURL, text: customBinding($customURL), prompt: Text(L.Profile.customPolicyURLPrompt))
                .autocorrectionDisabled()
            if !customURL.trimmingCharacters(in: .whitespaces).isEmpty, Self.httpsURL(customURL) == nil {
                StatusLine(.warning, L.Profile.invalidURL).font(.callout)
            }
            Picker(L.Profile.peopleDefault, selection: Binding(get: { customPeople }, set: { customPeople = $0; commitCustom() })) {
                ForEach(PeopleAIDefault.allCases, id: \.self) { Text(L.Profile.peopleDefaultName($0)).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Bindings & writes

    static let customID = "custom"

    private var fieldBinding: Binding<String> {
        Binding(get: { config.fieldID }, set: { id in if id != config.fieldID { config.fieldID = id } })
    }

    private var stageBinding: Binding<CareerStage> {
        Binding(get: { config.stage }, set: { s in if s != config.stage { config.stage = s } })
    }

    private var organizationBinding: Binding<String> {
        Binding(get: { config.organizationID }, set: { id in
            guard id != config.organizationID else { return }
            if id == Self.customID { commitCustom() }       // org.custom first, so "custom" resolves
            config.organizationID = id
        })
    }

    private func customBinding(_ field: Binding<String>) -> Binding<String> {
        Binding(get: { field.wrappedValue }, set: { field.wrappedValue = $0; commitCustom() })
    }

    /// `org.custom` from the editor (trimmed and capped by `OrganizationPresets.custom`; never texts).
    private func commitCustom() {
        let tools = customTools.split(whereSeparator: { ",;，；、".contains($0) }).map(String.init)
        let custom = OrganizationPresets.custom(name: customName, shortName: customShort, approvedAITools: tools,
                                                policyURL: Self.httpsURL(customURL), peopleDefault: customPeople,
                                                oneDriveRootHint: config.customOrganization?.mail.oneDriveRootHint)
        if custom != config.customOrganization { config.customOrganization = custom }
    }

    /// The reader description as stored: one line, at most 200 characters (the engine sanitizes
    /// it again before it enters the prompt); empty = composed from field and stage.
    private func commitReader(_ text: String) {
        let one = text.components(separatedBy: .newlines).joined(separator: " ")
        let capped = String(one.prefix(CardPromptProfile.maxReaderLength))
        readerDraft = capped
        let stored: String? = capped.trimmingCharacters(in: .whitespaces).isEmpty ? nil : capped
        if stored != config.readerOverride { config.readerOverride = stored }
    }

    static func httpsURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        readerDraft = config.readerOverride ?? ""
        if let c = config.customOrganization {
            customName = c.name.map { $0(L.lang) } ?? ""
            customShort = c.shortName ?? ""
            customTools = c.approvedAITools.joined(separator: ", ")
            customURL = c.policyURL?.absoluteString ?? ""
            customPeople = c.peopleDefault
        }
    }
}
