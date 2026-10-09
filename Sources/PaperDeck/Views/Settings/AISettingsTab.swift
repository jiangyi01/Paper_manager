import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

// MARK: - AI 解读（Claude / ChatGPT）

struct AISettingsTab: View {
    let state: AppState
    @State private var binary: BinaryLocator.Binary?
    @State private var codexBinary: BinaryLocator.Binary?
    @State private var locating = false
    @State private var codexModels: [CodexModelCatalog.Model] = []
    @State private var confirmTest = false
    @State private var testing = false
    @State private var testResult: (kind: StatusKind, text: String)?
    @State private var releasing = false
    @State private var confirmQueue = false

    var body: some View {
        @Bindable var settings = state.settings
        let provider = settings.agentProvider
        Form {
            masterSection(settings)
            switch provider {
            case .claude:
                ClaudeAccountSection(state: state, binary: binary)
                cliSection(settings)
            case .codex:
                CodexAccountSection(state: state, binary: codexBinary)
                codexCLISection(settings)
            }
            Section {
                Picker(L.Pref.newPapers, selection: $settings.autoReadNewPapers) {
                    Text(L.Pref.autoRead).tag(true)
                    Text(L.Pref.manualRead).tag(false)
                }
                modelPicker(settings, provider: provider)
                Picker(L.Pref.effort, selection: $settings.agentEffort) {
                    Text(L.Pref.effortLow).tag("low")
                    Text(L.Pref.effortMedium).tag("medium")
                }
                .pickerStyle(.segmented)
                Picker(L.Pref.textBudget, selection: $settings.textBudget) {
                    ForEach(Self.textBudgets(including: settings.textBudget), id: \.self) {
                        Text(L.Pref.characters($0)).tag($0)
                    }
                }
                Toggle(isOn: $settings.allowNewCategories) {
                    Text(L.Pref.allowNewCategories)
                    Text(L.Pref.allowNewCategoriesHint)
                }
            } header: {
                Text(L.Pref.readingSection)
            } footer: {
                if provider == .codex { NoteText(L.Pref.codexModelFooter) }
            }
            testSection(provider)
            AgentRunLogSection(state: state)
            Section {
                LabeledContent {
                    Text(L.Pref.comingSoon)
                } label: {
                    Label(L.Pref.otherProviders, systemImage: "puzzlepiece.extension")
                }
                .foregroundStyle(.tertiary)
                .disabled(true)
            }
        }
        .task(id: settings.cliPathOverride) {
            guard settings.agentProvider == .claude else { return }
            await locate(settings.cliPathOverride)
            await state.engine.cliPathOverrideDidChange()
        }
        .task(id: settings.codexPathOverride) {
            guard settings.agentProvider == .codex else { return }
            await locateCodex(settings.codexPathOverride)
            await state.engine.codexPathOverrideDidChange()
        }
        .task(id: provider) {
            // Switching provider: show the newly selected CLI right away (zero quota).
            testResult = nil
            switch provider {
            case .claude: if binary == nil { await locate(settings.cliPathOverride, debounce: false) }
            case .codex:
                if codexBinary == nil { await locateCodex(settings.codexPathOverride, debounce: false) }
                codexModels = await CodexModelCatalog.load(lang: settings.language)
            }
        }
        .alert(L.Pref.testConfirmTitle(provider), isPresented: $confirmTest) {
            Button(L.Pref.testRun) { runTest(provider) }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.Pref.testConfirmBody(provider))
        }
        .alert(L.Pref.queueConfirmTitle(state.agentStatus.held + Self.neverQueued(state).count), isPresented: $confirmQueue) {
            Button(L.Pref.queueConfirm) { queueExisting() }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.Pref.queueConfirmBody)
        }
    }

    // 解读服务 (Claude / ChatGPT) + 总开关「AI 解读」: off ↔ the chosen provider
    // (mock shows as on and is labelled).
    private func masterSection(_ settings: SettingsStore) -> some View {
        Section {
            Picker(selection: Binding(get: { settings.agentProvider }, set: { state.selectProvider($0) })) {
                ForEach(AIProviderKind.allCases, id: \.self) { kind in
                    Text(L.Pref.providerName(kind)).tag(kind)
                }
            } label: {
                Text(L.Pref.providerPicker)
                Text(L.Pref.providerPickerHint)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: Binding(get: { settings.aiEnabled }, set: { state.setAIReading($0) })) {
                Text(L.Pref.aiReading)
                Text(L.Pref.modeCaption(settings.agentMode, provider: settings.agentProvider))
            }
            .toggleStyle(.switch)
            let waiting = state.agentStatus.held + Self.neverQueued(state).count
            if settings.aiEnabled, waiting > 0 {
                LabeledContent {
                    Button {
                        confirmQueue = true
                    } label: {
                        if releasing { ProgressView().controlSize(.small) } else { Text(L.Pref.queueExisting(waiting)) }
                    }
                    .disabled(releasing)
                } label: {
                    Text(L.Pref.heldPapers(waiting))
                    Text(L.Pref.heldPapersHint)
                }
            }
        } footer: {
            HStack(alignment: .top, spacing: 6) {
                NoteText(L.Pref.privacyNote(settings.agentProvider), symbol: "lock.shield")
                Spacer(minLength: 0)
                HelpButton(.aiWithout)
            }
        }
    }

    @ViewBuilder
    private func modelPicker(_ settings: SettingsStore, provider: AIProviderKind) -> some View {
        switch provider {
        case .claude:
            Picker(L.Pref.model, selection: Bindable(settings).agentModel) {
                Text(L.Pref.modelSonnet).tag("sonnet")
                Text(L.Pref.modelOpus).tag("opus")
                Text(L.Pref.modelHaiku).tag("haiku")
            }
        case .codex:
            Picker(L.Pref.model, selection: Bindable(settings).codexModel) {
                ForEach(CodexModelCatalog.choices(codexModels, including: settings.codexModel, lang: settings.language)) { m in
                    Text(L.Pref.codexModel(m.name, detail: m.detail)).tag(m.id)
                }
            }
        }
    }

    private func cliSection(_ settings: SettingsStore) -> some View {
        Section {
            LabeledContent(L.Pref.cliDetected) {
                detectedBinary(binary, notFound: L.Pref.cliNotFound)
            }
            TextField(L.Pref.cliOverride, text: Bindable(settings).cliPathOverride, prompt: Text(L.Pref.cliOverridePrompt))
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
        } header: {
            Text(L.Pref.cliSection)
        } footer: {
            NoteText(L.Pref.cliFooter)
        }
    }

    private func codexCLISection(_ settings: SettingsStore) -> some View {
        Section {
            LabeledContent(L.Pref.cliDetected) {
                detectedBinary(codexBinary, notFound: L.Pref.codexNotInstalled)
            }
            TextField(L.Pref.cliOverride, text: Bindable(settings).codexPathOverride, prompt: Text(L.Pref.cliOverridePrompt))
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
        } header: {
            Text(L.Pref.codexCLISection)
        } footer: {
            NoteText(L.Pref.codexCLIFooter)
        }
    }

    @ViewBuilder
    private func detectedBinary(_ binary: BinaryLocator.Binary?, notFound: String) -> some View {
        if locating {
            ProgressView().controlSize(.small)
        } else if let binary {
            Text("\(SettingsFormat.tildePath(binary.path)) · \(binary.version)")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(notFound).foregroundStyle(.secondary)
        }
    }

    private func testSection(_ provider: AIProviderKind) -> some View {
        Section {
            LabeledContent {
                Button {
                    confirmTest = true
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text(L.Pref.testButton) }
                }
                .disabled(testing)
            } label: {
                Text(L.Pref.testConnection)
                Text(L.Pref.testConnectionHint(provider, model: provider == .codex
                    ? CodexModelCatalog.displayName(Self.codexTestModel(codexModels)) : nil))
            }
            if testing {
                StatusLine(.working, L.Pref.testRunning)
            } else if let testResult {
                StatusLine(testResult.kind, testResult.text)
            }
        }
    }

    // MARK: Actions

    /// Papers without a card that were never queued (imported before AI existed / failed detection).
    static func neverQueued(_ state: AppState) -> [Int64] {
        (state.snapshot?.rows ?? []).filter { $0.paper.card == nil && $0.paper.aiState == .none }.map(\.paper.pk)
    }

    /// 为现有 N 篇论文排队解读: every held job (incl. those held while the mode was off)
    /// plus the papers that never had a job.
    private func queueExisting() {
        releasing = true
        let agents = state.engine.agents
        let pks = Self.neverQueued(state)
        Task {
            await agents.releaseHeld(paperPKs: nil)
            for pk in pks { await agents.enqueue(paperPK: pk, hold: false) }
            releasing = false
        }
    }

    private func locate(_ override: String, debounce: Bool = true) async {
        locating = true
        // Debounce typing in the override field.
        if debounce { try? await Task.sleep(for: .milliseconds(400)) }
        guard !Task.isCancelled else { return }
        binary = await ClaudeBinaryProbe.locate(override: override)
        locating = false
    }

    private func locateCodex(_ override: String, debounce: Bool = true) async {
        locating = true
        if debounce { try? await Task.sleep(for: .milliseconds(400)) }
        guard !Task.isCancelled else { return }
        codexBinary = await CodexBinaryProbe.locate(override: override)
        locating = false
    }

    private func runTest(_ provider: AIProviderKind) {
        testing = true
        testResult = nil
        Task {
            // ChatGPT: a model this plan's cache lists (today's GPT-5.6-Luna when it does).
            let model = provider == .codex ? Self.codexTestModel(codexModels) : nil
            let outcome = await state.engine.agents.testConnection(provider: provider, model: model)
            // The user may have switched provider while the test ran; the result is still the tested one's.
            testResult = Self.describe(outcome, provider: provider)
            testing = false
        }
    }

    static func describe(_ o: AgentOutcome, provider: AIProviderKind = .claude) -> (kind: StatusKind, text: String) {
        switch o {
        case .success(_, let meta):
            let tokens: Int? = meta.costUSD == nil ? Self.totalTokens(meta) : nil
            return (.ok, L.Pref.testOK(model: meta.model, seconds: meta.durationMs.map { Double($0) / 1000 },
                                       cost: meta.costUSD, tokens: tokens))
        case .usageLimit(let at): return (.warning, L.Pref.testUsageLimit(at.map(SettingsFormat.shortDateTime)))
        case .notLoggedIn: return (.error, L.Pref.testNotLoggedIn(provider))
        case .overloaded: return (.warning, L.Pref.testOverloaded(provider))
        case .invalidOutput(let m): return (.error, L.Pref.testInvalid(m))
        case .maxTurns: return (.error, L.Pref.testMaxTurns)
        case .timeout: return (.error, L.Pref.testTimeout)
        case .binaryMissing: return (.error, L.Pref.testNotFound(provider))
        case .cancelled: return (.neutral, L.Pref.testCancelled)
        case .generic(let m): return (.error, L.Pref.testError(m))
        }
    }

    /// Input + output tokens of a run (Codex reports no cost estimate).
    static func totalTokens(_ meta: RunMeta) -> Int? {
        guard meta.inputTokens != nil || meta.outputTokens != nil else { return nil }
        return (meta.inputTokens ?? 0) + (meta.outputTokens ?? 0)
    }

    /// The ChatGPT connection test's model: GPT-5.6-Luna when the Codex CLI's cache lists it (or
    /// has no list), otherwise the first cached model.
    static func codexTestModel(_ models: [CodexModelCatalog.Model]) -> String {
        let luna = AIProviderKind.codex.connectionTestModel
        guard let first = models.first, !models.contains(where: { $0.id == luna }) else { return luna }
        return first.id
    }

    static func textBudgets(including current: Int) -> [Int] {
        Array(Set([40_000, 120_000, 300_000, current])).sorted()
    }
}

/// Login state from the agent queue's zero-quota detection (`claude auth status`).
struct ClaudeAccountSection: View {
    let state: AppState
    let binary: BinaryLocator.Binary?

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    var body: some View {
        Section {
            ClaudeStatusView(state: state, binary: binary)
        } header: {
            HStack(spacing: 6) {
                Text(L.Pref.accountSection)
                HelpButton(.aiSetup)
            }
        }
        .task { await state.engine.agents.wake() }
    }
}

/// Shared by settings ▸ AI and setup assistant row 1.
struct ClaudeStatusView: View {
    let state: AppState
    let binary: BinaryLocator.Binary?

    var body: some View {
        // Right after a Claude ⇄ ChatGPT switch the status may still describe the other provider.
        let provider: AgentQueueStatus.Provider = state.agentStatus.describes(.claude) ? state.agentStatus.provider : .unknown
        switch provider {
        case .ready(let plan, let version):
            StatusLine(.ok, L.Pref.claudeReady(plan: SettingsFormat.plan(plan),
                                               path: binary.map { SettingsFormat.tildePath($0.path) }, version: version))
        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(.error, L.Pref.claudeNotInstalled)
                CommandBox(command: ClaudeAccountSection.installCommand)
                HStack {
                    Button(L.Pref.openTerminal) { SystemLinks.openTerminal() }
                    Button(L.Pref.recheck) { wake() }
                }
                .controlSize(.small)
            }
        case .notLoggedIn:
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(.warning, L.Pref.claudeNotLoggedIn)
                if case .nonSubscription = provider.reason {
                    NoteText(provider.reasonText(state.settings.language, provider: .claude))
                }
                NoteText(L.Pref.claudeLoginHint)
                HStack {
                    Button(L.Pref.iLoggedIn) { wake() }
                    Button(L.Pref.openTerminal) { SystemLinks.openTerminal() }
                }
                .controlSize(.small)
            }
        case .unsupported:
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(.warning, L.Pref.claudeUnsupported)
                NoteText(provider.reasonText(state.settings.language, provider: .claude))
                Button(L.Pref.recheck) { wake() }.controlSize(.small)
            }
        case .unknown, .disabled:
            StatusLine(.working, L.Pref.claudeDetecting)
        }
    }

    private func wake() {
        let agents = state.engine.agents
        Task { await agents.wake(forceDetect: true) }
    }
}

/// ChatGPT login state from the queue's zero-quota detection (`codex login status`).
struct CodexAccountSection: View {
    let state: AppState
    let binary: BinaryLocator.Binary?

    var body: some View {
        Section {
            CodexStatusView(state: state, binary: binary)
        } header: {
            HStack(spacing: 6) {
                Text(L.Pref.codexAccountSection)
                HelpButton(.aiSetup)
            }
        }
        .task { await state.engine.agents.wake() }
    }
}

/// Shared by settings ▸ AI and setup assistant row 1 (ChatGPT chosen).
struct CodexStatusView: View {
    let state: AppState
    let binary: BinaryLocator.Binary?

    var body: some View {
        let provider: AgentQueueStatus.Provider = state.agentStatus.describes(.codex) ? state.agentStatus.provider : .unknown
        let login = CodexBinaryProbe.loginCommand(path: binary?.path)
        switch provider {
        case .ready(_, let version):
            StatusLine(.ok, L.Pref.codexReady(version: version))
        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(.error, L.Pref.codexNotInstalled)
                NoteText(L.Pref.codexInstallHint)
                CommandBox(command: L.Pref.codexBrewCommand)
                HStack {
                    Button(L.Pref.openTerminal) { SystemLinks.openTerminal() }
                    Button(L.Pref.recheck) { wake() }
                }
                .controlSize(.small)
            }
        case .notLoggedIn:
            VStack(alignment: .leading, spacing: 8) {
                if case .nonSubscription(let method) = provider.reason {
                    StatusLine(.warning, provider.reasonText(state.settings.language, provider: .codex))
                    NoteText(L.Pref.codexNonSubscription(Self.methodName(method)))
                } else {
                    StatusLine(.warning, L.Pref.codexNotLoggedIn)
                    NoteText(L.Pref.codexLoginHint)
                }
                CommandBox(command: login)
                HStack {
                    Button(L.Pref.iLoggedIn) { wake() }
                    Button(L.Pref.openTerminal) { SystemLinks.openTerminal() }
                }
                .controlSize(.small)
            }
        case .unsupported:
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(.warning, provider.reasonText(state.settings.language, provider: .codex))
                Button(L.Pref.recheck) { wake() }.controlSize(.small)
            }
        case .unknown, .disabled:
            StatusLine(.working, L.Pref.codexDetecting)
        }
    }

    /// `api_key` → "API key", `access_token` → "access token".
    static func methodName(_ code: String) -> String {
        switch code.lowercased() {
        case "api_key", "apikey", "api-key": return "API key"
        default: return code.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func wake() {
        let agents = state.engine.agents
        Task { await agents.wake(forceDetect: true) }
    }
}

/// 运行日志 — the last 50 agent jobs (cost is the CLI's client-side estimate).
struct AgentRunLogSection: View {
    let state: AppState
    @State private var jobs: [AgentJob] = []
    @State private var titles: [Int64: String] = [:]
    @State private var showAll = false

    var body: some View {
        Section {
            if jobs.isEmpty {
                Text(L.Pref.runLogEmpty).foregroundStyle(.secondary)
            } else {
                ForEach(showAll ? jobs : Array(jobs.prefix(8)), id: \.pk) { job in
                    AgentJobRow(job: job, title: titles[job.paperPK] ?? L.Pref.deletedPaper)
                }
                if jobs.count > 8 {
                    Button(showAll ? L.Pref.showLess : L.Pref.showAll(jobs.count)) { showAll.toggle() }
                        .buttonStyle(.link)
                }
            }
        } header: {
            HStack {
                Text(L.Pref.runLog)
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L.Pref.refresh)
            }
        } footer: {
            NoteText(L.Pref.costFooter)
        }
        .task(id: state.agentStatus) { await reload() }
    }

    private func reload() async {
        let loaded = (try? await state.engine.db.recentJobs(limit: 50)) ?? []
        let wanted = Set(loaded.map(\.paperPK))
        var names: [Int64: String] = [:]
        if let snap = state.snapshot {
            for row in snap.rows where wanted.contains(row.paper.pk) { names[row.paper.pk] = row.paper.title }
            for row in snap.deleted where wanted.contains(row.paper.pk) { names[row.paper.pk] = row.paper.title }
        }
        jobs = loaded
        titles = names
    }
}

private struct AgentJobRow: View {
    let job: AgentJob
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
                .accessibilityLabel(stateText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(stateText).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// `9月30日 10:42 · ChatGPT gpt-5.6-terra · 1:05 · 12.3k tokens`.
    private var details: String {
        var parts = [SettingsFormat.shortDateTime(job.finishedAt ?? job.startedAt ?? job.createdAt)]
        let kind = AIProviderKind(rawValue: job.provider)
        switch (kind, job.model) {
        case (let k?, let m?): parts.append("\(k.shortName) \(Self.shortModel(m))")
        case (let k?, nil): parts.append(k.shortName)
        case (nil, let m?): parts.append(Self.shortModel(m))
        case (nil, nil): break
        }
        if let d = job.durationMs { parts.append(SettingsFormat.duration(ms: d)) }
        if let c = job.costUSD {
            parts.append(L.Pref.estimatedCost(c))
        } else if job.state == .succeeded, job.inputTokens != nil || job.outputTokens != nil {
            parts.append(L.Pref.tokens((job.inputTokens ?? 0) + (job.outputTokens ?? 0)))
        }
        if job.provider == "mock" { parts.append("MOCK") }
        return parts.joined(separator: " · ")
    }

    private var stateText: String { L.Pref.jobState(job.state) }

    private var symbol: String {
        switch job.state {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .running: "circle.dotted.circle"
        case .queued: "clock"
        case .held: "pause.circle"
        case .cancelled: "minus.circle"
        }
    }

    private var tint: Color {
        switch job.state {
        case .succeeded: .green
        case .failed: .red
        case .running: .purple
        default: .secondary
        }
    }

    /// `claude-sonnet-4-5-20250929` → `sonnet-4-5`.
    static func shortModel(_ m: String) -> String {
        var s = m.hasPrefix("claude-") ? String(m.dropFirst(7)) : m
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }
}
