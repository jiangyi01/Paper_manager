import AppKit
import SwiftUI
import PaperDeckCore

/// Settings ▸ Mail ▸ AI triage: mode (AI / local rules only), provider and model per provider,
/// the daily cap (「今天 4/30」), the body cap and 「显示发送给 AI 的内容示例」.
struct MailTriageSection: View {
    let state: AppState
    let usage: MailTriageUsage?
    @Binding var sheet: MailSettingsSheet?
    /// The ChatGPT models the Codex CLI's cache lists (`CodexModelCatalog`, as Settings ▸ AI).
    @State private var codexCatalog: [CodexModelCatalog.Model] = []

    static let claudeModels = ["haiku", "sonnet"]
    /// The triage's recommended ChatGPT models (fast ones first) when the cache has no list.
    static let codexModels = ["gpt-5.6-luna", "gpt-5.6-terra"]
    static let dailyCaps = [10, 20, 30, 50, 100]
    static let bodyCaps = [4_000, 8_000, 12_000, 20_000]

    var body: some View {
        @Bindable var settings = state.settings
        Section {
            Picker(L.MailPref.triageMode, selection: $settings.mailAIMode) {
                Text(L.MailPref.modeAI).tag(MailSettings.AIMode.ai)
                Text(L.MailPref.modeLocal).tag(MailSettings.AIMode.heuristicOnly)
            }
            .pickerStyle(.segmented)
            NoteText(settings.mailAIMode == .ai ? L.MailPref.modeAIHint : L.MailPref.modeLocalHint)
            if settings.mailAIMode == .ai {
                Picker(L.MailPref.triageProvider, selection: $settings.mailTriageProvider) {
                    Text(L.MailPref.sameAsReading(settings.activeProvider ?? settings.agentProvider)).tag(AIProviderKind?.none)
                    ForEach(AIProviderKind.allCases, id: \.self) { Text(L.Pref.providerName($0)).tag(AIProviderKind?.some($0)) }
                }
                Picker(L.MailPref.claudeModel, selection: $settings.mailTriageModelClaude) {
                    ForEach(Self.choices(Self.claudeModels, current: settings.mailTriageModelClaude), id: \.self) {
                        Text(L.MailPref.triageModelName($0)).tag($0)
                    }
                }
                Picker(L.MailPref.codexModel, selection: $settings.mailTriageModelCodex) {
                    ForEach(Self.codexChoices(codexCatalog, current: settings.mailTriageModelCodex, lang: settings.language)) { m in
                        Text(Self.codexLabel(m)).tag(m.id)
                    }
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        if let usage {
                            Text(L.MailPref.todayUsage(usage.used, usage.limit))
                                .monospacedDigit()
                                .foregroundStyle(usage.isExhausted ? .orange : .secondary)
                        }
                        Picker(L.MailPref.dailyCap, selection: $settings.mailTriageDailyMax) {
                            ForEach(MailSettingsFormat.options(Self.dailyCaps, including: settings.mailTriageDailyMax), id: \.self) {
                                Text(L.MailPref.perDay($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } label: {
                    Text(L.MailPref.dailyCap)
                    Text(L.MailPref.dailyCapHint)
                }
                Picker(selection: $settings.mailTriageBodyCap) {
                    ForEach(MailSettingsFormat.options(Self.bodyCaps, including: settings.mailTriageBodyCap), id: \.self) {
                        Text(L.Pref.characters($0)).tag($0)
                    }
                } label: {
                    Text(L.MailPref.bodyCap)
                    Text(L.MailPref.bodyCapHint)
                }
                let route = MailTriageRoute.of(provider: settings.mailTriageProvider, settings: settings.engineSettings)
                if let held = route.heldText(settings.language) {
                    StatusLine(.warning, held)
                }
                LabeledContent {
                    Button(L.MailPref.showSample) { sheet = .triageSample }
                } label: {
                    Text(L.MailPref.whatIsSent)
                    Text(L.MailPref.whatIsSentHint)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(L.MailPref.triageSection)
                HelpButton(.mailSendersAndAI)
            }
        } footer: {
            NoteText(L.MailPref.triagePrivacy, symbol: "lock.shield")
        }
        .task(id: settings.mailAIMode) {
            guard settings.mailAIMode == .ai, codexCatalog.isEmpty else { return }
            codexCatalog = await Self.cachedCodexModels()
        }
    }

    static func choices(_ base: [String], current: String) -> [String] {
        base.contains(current) || current.isEmpty ? base : base + [current]
    }

    /// The models the Codex CLI's cache lists (`CodexModelCatalog.parse`; reads only that file),
    /// empty without a cache.
    static func cachedCodexModels(url: URL = CodexModelCatalog.cacheURL) async -> [CodexModelCatalog.Model] {
        let cached = await BlockingIO.run { () -> [(slug: String, name: String)]? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return CodexModelCatalog.parse(data)
        }
        return (cached ?? []).map { CodexModelCatalog.Model(id: $0.slug, name: $0.name, detail: nil) }
    }

    /// The triage's ChatGPT picker: without a cache, today's two (fast first); with one, the
    /// recommended fast models it lists, then its other models — plus the current setting.
    static func codexChoices(_ catalog: [CodexModelCatalog.Model], current: String, lang: UILang) -> [CodexModelCatalog.Model] {
        func model(_ slug: String) -> CodexModelCatalog.Model {
            catalog.first { $0.id == slug } ?? CodexModelCatalog.Model(id: slug, name: CodexModelCatalog.displayName(slug), detail: nil)
        }
        guard !catalog.isEmpty else { return choices(codexModels, current: current).map(model) }
        let cached = Set(catalog.map(\.id))
        var out = codexModels.filter(cached.contains).map(model)
        for m in catalog where !out.contains(where: { $0.id == m.id }) { out.append(m) }
        if !current.isEmpty, !out.contains(where: { $0.id == current }) { out.append(model(current)) }
        return out
    }

    /// Known slugs keep their triage wording ("GPT-5.6-Luna — fast, less quota (recommended)").
    static func codexLabel(_ m: CodexModelCatalog.Model) -> String {
        let known = L.MailPref.triageModelName(m.id)
        return known != m.id ? known : L.Pref.codexModel(m.name, detail: m.detail)
    }
}

/// 「显示发送给 AI 的内容示例」: a made-up advisor email run through the real pipeline with the
/// user's criteria, categories and tags — the exact stdin a triage run would get, its size and
/// the provider / model, plus the fixed system prompt.
struct MailTriageSampleSheet: View {
    let state: AppState
    let onClose: () -> Void
    @State private var sample: MailTriagePreview.Result?
    @State private var showPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L.MailPref.sampleTitle).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NoteText(L.MailPref.sampleIntro, symbol: "info.circle")
                    if let s = sample {
                        StatusLine(.neutral, L.MailPref.sampleMeta(provider: s.provider.shortName, model: s.model,
                                                                   bytes: s.stdin.count))
                        if let held = s.route.heldText(state.settings.language) {
                            StatusLine(.warning, held)
                        }
                        block(s.stdinText)
                        DisclosureGroup(L.MailPref.systemPrompt, isExpanded: $showPrompt) {
                            block(MailTriageSchema.systemPrompt)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                if let s = sample {
                    Button(L.Pref.copy) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s.stdinText, forType: .string)
                    }
                }
                Spacer()
                Button(L.MailPref.done) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 700)
        .task { await build() }
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.fill.quaternary))
    }

    private func build() async {
        let settings = state.settings.mailSettings
        let engineSettings = state.settings.engineSettings
        let db = state.engine.db
        let categories = ((try? await db.categories()) ?? []).map(\.name)
        let tags = ((try? await db.frequentTags(limit: MailTriageSchema.maxFrequentTags)) ?? []).map(\.name)
        sample = await BlockingIO.run {
            MailTriagePreview.sample(settings: settings, engineSettings: engineSettings,
                                     categories: categories, frequentTags: tags)
        }
    }
}
