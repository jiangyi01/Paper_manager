import AppKit
import SwiftUI
import UserNotifications
import PaperDeckCore
import PaperDeckShared

/// 设置助手 (§8): first run, six rows with status indicators. 「完成」 needs row 1 (a
/// decision about AI reading — Claude or ChatGPT) and row 3 (a usable library folder); the rest are optional.
struct SetupAssistantView: View {
    let state: AppState
    let onFinish: () -> Void

    @State private var claudeDeclined = false
    @State private var libraryUsable = false

    private var claudeDecided: Bool { state.settings.aiEnabled || claudeDeclined }
    private var canFinish: Bool { claudeDecided && libraryUsable }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    SetupClaudeStep(state: state, declined: $claudeDeclined)
                    // Certificates only matter for a build made on this Mac.
                    if BuildIdentity.current.channel == .local { SetupSigningStep() }
                    SetupLibraryStep(state: state, usable: $libraryUsable)
                    SetupNotificationStep()
                    SetupPlanStep(settings: state.settings)
                    SetupImportStep(state: state)
                }
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L.Pref.setupWelcome).font(.title2.weight(.semibold))
                Text(L.Pref.setupSubtitle).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if canFinish {
                StatusLine(.ok, L.Pref.setupReady).font(.callout)
            } else {
                NoteText(L.Pref.setupFinishHint, symbol: "info.circle")
            }
            Spacer()
            Button(L.Pref.finish) {
                state.settings.setupCompleted = true
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canFinish)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

// MARK: - Step card

struct SetupStepCard<Content: View>: View {
    /// The Setup Assistant's step number (nil: no badge — a step reused on a page of the setup window).
    let number: Int?
    let title: String
    let kind: StatusKind
    let statusText: String
    var required = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let number {
                    Text("\(number)")
                        .font(.callout.weight(.bold).monospacedDigit())
                        .frame(width: 24, height: 24)
                        .background(kind.tint.opacity(kind == .ok ? 0.2 : 0.12), in: Circle())
                        .accessibilityHidden(true)
                }
                Text(title).font(.headline)
                if required {
                    Text(L.Pref.requiredTag)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.fill.tertiary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StatusLine(kind, statusText)
                    .font(.callout)
                    .foregroundStyle(kind == .ok ? .primary : .secondary)
            }
            content
                .padding(.leading, number == nil ? 0 : 34)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel((number.map { "\($0). " } ?? "") + "\(title), \(statusText)")
    }
}

// MARK: - 1 AI 解读（Claude / ChatGPT）

private struct SetupClaudeStep: View {
    let state: AppState
    @Binding var declined: Bool
    @State private var binary: BinaryLocator.Binary?
    @State private var codexBinary: BinaryLocator.Binary?

    var body: some View {
        let enabled = state.settings.aiEnabled
        let provider = state.settings.agentProvider
        SetupStepCard(number: 1, title: L.Pref.setupClaudeTitle, kind: kind(enabled), statusText: statusText(enabled), required: true) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L.Pref.providerPicker, selection: Binding(get: { provider }, set: { state.selectProvider($0) })) {
                    ForEach(AIProviderKind.allCases, id: \.self) { kind in
                        Text(L.Pref.providerName(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                NoteText(L.Pref.setupProviderHint)
                switch provider {
                case .claude: ClaudeStatusView(state: state, binary: binary)
                case .codex: CodexStatusView(state: state, binary: codexBinary)
                }
                NoteText(L.Pref.privacyNote(provider), symbol: "lock.shield")
                HStack(spacing: 10) {
                    if enabled {
                        StatusLine(.ok, L.Pref.claudeEnabled(state.settings.agentMode))
                        Button(L.Pref.turnOff) { state.setAIReading(false) }.controlSize(.small)
                    } else {
                        Button(L.Pref.enableProvider(provider)) {
                            declined = false
                            state.setAIReading(true)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(L.Pref.notNow) { declined = true }
                            .disabled(declined)
                    }
                }
            }
        }
        .task(id: provider) {
            await state.engine.agents.wake()
            switch provider {
            case .claude: binary = await ClaudeBinaryProbe.locate(override: state.settings.cliPathOverride)
            case .codex: codexBinary = await CodexBinaryProbe.locate(override: state.settings.codexPathOverride)
            }
        }
    }

    private var ready: Bool {
        guard state.agentStatus.describes(state.settings.agentProvider) else { return false }
        if case .ready = state.agentStatus.provider { return true }
        return false
    }

    private func kind(_ enabled: Bool) -> StatusKind {
        if enabled { return ready ? .ok : .warning }
        return declined ? .neutral : .pending
    }

    private func statusText(_ enabled: Bool) -> String {
        if enabled { return ready ? L.Pref.stepEnabled : L.Pref.stepEnabledNeedsLogin }
        return declined ? L.Pref.stepSkipped : L.Pref.stepTodo
    }
}

// MARK: - 2 稳定签名证书

private struct SetupSigningStep: View {
    @State private var signing: CodeSigningProbe.Kind?

    var body: some View {
        SetupStepCard(number: 2, title: L.Pref.setupSigningTitle, kind: kind, statusText: statusText) {
            VStack(alignment: .leading, spacing: 8) {
                switch signing {
                case .certificate(let name): StatusLine(.ok, L.Pref.signedWith(name))
                case .adhoc: StatusLine(.warning, L.Pref.signedAdhoc)
                case .unsigned: StatusLine(.warning, L.Pref.unsignedBuild)
                case nil: StatusLine(.working, L.Pref.checking)
                }
                NoteText(L.Pref.signingWhy)
                if signing != nil, !isCertificate {
                    DisclosureGroup(L.Pref.signingHowTo) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(L.Pref.signingSteps.enumerated()), id: \.offset) { i, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                                    Text(step).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            CommandBox(command: "./build_app.sh")
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
        .task { signing = await CodeSigningProbe.current() }
    }

    private var isCertificate: Bool {
        if case .certificate = signing { return true }
        return false
    }

    private var kind: StatusKind {
        switch signing {
        case .certificate: .ok
        case nil: .working
        default: .warning
        }
    }

    private var statusText: String {
        switch signing {
        case .certificate: L.Pref.stepDone
        case nil: L.Pref.checking
        default: L.Pref.stepRecommended
        }
    }
}

// MARK: - 3 资料库文件夹

private struct SetupLibraryStep: View {
    let state: AppState
    @Binding var usable: Bool
    @State private var status: LibraryStatus?
    @State private var working = false

    static let sampleName = FileNamer.folderName(
        year: 2024, firstAuthor: "Li Wang",
        title: "Molecular and cellular dynamics of the developing human neocortex")

    var body: some View {
        let path = chosenPath
        let restartNeeded = path.standardizedFileURL.path != state.engine.paths.library.standardizedFileURL.path
        SetupStepCard(number: 3, title: L.Pref.setupLibraryTitle, kind: kind, statusText: statusText, required: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(.tint).accessibilityHidden(true)
                    Text(SettingsFormat.tildePath(path.path))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                statusLine
                if let status, !status.isUsable {
                    HStack {
                        if status == .denied {
                            Button(L.Pref.openSystemSettings) { SystemLinks.filesAndFolders() }
                        }
                        Button(L.useAlternativeLibrary) { useAlternative() }
                        Button(L.retry) { Task { await probe() } }
                    }
                    .controlSize(.small)
                    .disabled(working)
                }
                if restartNeeded {
                    NoteText(L.Pref.restartToApply, symbol: "arrow.clockwise.circle")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.Pref.namingPreview).font(.callout).foregroundStyle(.secondary)
                    Text("Papers/\(Self.sampleName)/\(FileNamer.pdfName(forFolder: Self.sampleName))")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(Self.sampleName)
                }
            }
        }
        .task { await probe() }
    }

    /// The folder the running engine actually opened — unless the user just switched it here
    /// (the new location applies after a restart).
    @State private var switchedHere = false
    private var chosenPath: URL {
        switchedHere ? URL(fileURLWithPath: state.settings.libraryPath, isDirectory: true) : state.engine.paths.library
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .ok?: StatusLine(.ok, L.Pref.libraryOK)
        case .ubiquitous?: StatusLine(.warning, L.Pref.libraryUbiquitous)
        case .denied?: StatusLine(.error, L.Pref.libraryDenied)
        case .missing?: StatusLine(.error, L.Pref.libraryMissing)
        case .readOnly?: StatusLine(.error, L.Pref.libraryReadOnly)
        case nil: StatusLine(.working, L.Pref.checking)
        }
    }

    private var kind: StatusKind {
        guard let status else { return .working }
        return status.isUsable ? .ok : .error
    }

    private var statusText: String {
        guard let status else { return L.Pref.checking }
        return status.isUsable ? L.Pref.stepDone : L.Pref.stepNeedsAction
    }

    private func probe() async {
        working = true
        let s = await LibraryProbe.status(of: chosenPath)
        status = s
        usable = s.isUsable
        working = false
    }

    private func useAlternative() {
        working = true
        Task {
            if let alt = await LibraryProbe.createAlternative() {
                state.settings.libraryPath = alt.path
                switchedHere = true
            }
            await probe()
        }
    }
}

// MARK: - 4 通知

struct SetupNotificationStep: View {
    @State private var sending = false
    private var reminders: ReminderService? { ReminderService.shared }

    var body: some View {
        let status = reminders?.authorization ?? .notDetermined
        let available = reminders?.notificationsAvailable == true
        SetupStepCard(number: 4, title: L.Pref.setupNotificationsTitle,
                      kind: NotificationAuthorizationRow.kind(status, available: available),
                      statusText: NotificationAuthorizationRow.text(status, available: available)) {
            VStack(alignment: .leading, spacing: 10) {
                NoteText(L.Pref.notificationsWhy)
                HStack(spacing: 10) {
                    switch status {
                    case .notDetermined:
                        Button(L.Pref.allowNotifications) {
                            Task { _ = await reminders?.requestAuthorization() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!available)
                    case .denied:
                        Button(L.Pref.openNotificationSettings) { ReminderService.openSystemNotificationSettings() }
                            .disabled(!available)
                    default:
                        EmptyView()
                    }
                    Button {
                        sending = true
                        Task {
                            await reminders?.sendTest()
                            sending = false
                        }
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Text(L.Pref.sendTest) }
                    }
                    .disabled(sending || reminders == nil)
                }
                NoteText(L.Pref.alertStyleHint, symbol: "lightbulb")
            }
        }
        .task { await reminders?.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reminders?.refreshAuthorization() }
        }
    }
}

// MARK: - 5 阅读计划

struct SetupPlanStep: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SetupStepCard(number: 5, title: L.Pref.setupPlanTitle, kind: .ok, statusText: L.Pref.stepDefaultsOK) {
            VStack(alignment: .leading, spacing: 10) {
                BudgetPicker(settings: settings).fixedSize()
                WeekdayPicker(settings: settings)
                ReminderTimePicker(settings: settings).fixedSize()
                NoteText(L.Pref.planFooter)
            }
        }
    }
}

// MARK: - 6 导入已有论文（可选）

struct SetupImportStep: View {
    let state: AppState
    /// Where the folder panel opens (nil: `defaultFolder`).
    var startFolder: URL? = nil
    /// The Setup Assistant's step number; nil on the setup window's Import page (its own page).
    var number: Int? = 6
    @State private var folder: URL?
    @State private var pdfCount: Int?
    @State private var unscheduled = false
    @State private var queueAll = true
    @State private var importing = false
    @State private var summary: ImportBatchSummary?

    var body: some View {
        @Bindable var settings = state.settings
        let claudeOn = settings.agentMode != "off"
        SetupStepCard(number: number, title: L.Pref.setupImportTitle, kind: kind, statusText: statusText) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(folder == nil ? L.Pref.chooseFolder : L.Pref.chooseAnotherFolder) { choose() }
                        .disabled(importing)
                    if let folder {
                        Text(SettingsFormat.tildePath(folder.path))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let pdfCount { Text(L.Pref.pdfCount(pdfCount)).foregroundStyle(.secondary) }
                    }
                }
                if folder != nil, summary == nil {
                    Picker(L.Pref.importMode, selection: $settings.importMode) {
                        Text(L.Pref.importCopy).tag("copy")
                        Text(L.Pref.importMove).tag("move")
                    }
                    .fixedSize()
                    Picker(L.Pref.scheduling, selection: $unscheduled) {
                        Text(L.Pref.scheduleSequential).tag(false)
                        Text(L.Pref.scheduleNone).tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    if claudeOn {
                        Picker(L.Pref.claudeForImport, selection: $queueAll) {
                            Text(L.Pref.queueAll).tag(true)
                            Text(L.Pref.later).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    } else {
                        NoteText(L.Pref.importClaudeOff, symbol: "sparkles")
                    }
                    HStack {
                        Button(L.Pref.startImport(pdfCount ?? 0)) { runImport(claudeOn: claudeOn) }
                            .buttonStyle(.borderedProminent)
                            .disabled(importing || (pdfCount ?? 0) == 0)
                        if importing {
                            ProgressView().controlSize(.small)
                            Text(L.Pref.importing).foregroundStyle(.secondary)
                        }
                    }
                }
                if let summary {
                    StatusLine(summary.failed > 0 ? .warning : .ok, L.Pref.importDone(summary))
                } else if folder == nil {
                    NoteText(L.Pref.importHint)
                }
            }
        }
        // The batch dialog would ask again what this step already decided.
        .onChange(of: state.pendingBatch?.batchID) { _, id in
            if let id, id == summary?.batchID { state.pendingBatch = nil }
        }
    }

    private var kind: StatusKind {
        if importing { return .working }
        return summary == nil ? .neutral : .ok
    }

    private var statusText: String {
        if importing { return L.Pref.importing }
        return summary == nil ? L.Pref.stepOptional : L.Pref.stepDone
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = startFolder ?? Self.defaultFolder(state.settings)
        panel.prompt = L.Pref.choose
        panel.message = L.Pref.chooseImportMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        state.settings.config.importLastFolder = SettingsFormat.tildePath(url.path)
        pdfCount = nil
        summary = nil
        Task { pdfCount = await FolderScan.countPDFs(in: url) }
    }

    /// `import.lastFolder` (an existing install keeps today's folder through the migration), else
    /// ~/Downloads.
    static func defaultFolder(_ settings: SettingsStore) -> URL {
        let home = SharedPaths.realHome
        if let last = settings.config.importLastFolder, !last.isEmpty {
            let path = last == "~" ? home.path : (last.hasPrefix("~/") ? home.path + last.dropFirst(1) : last)
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func runImport(claudeOn: Bool) {
        guard let folder else { return }
        importing = true
        let options = ImportOptions(origin: .setupAssistant,
                                    scheduling: unscheduled ? .unscheduled : .sequentialLow,
                                    ai: claudeOn && queueAll ? .queueAll : .hold)
        let intake = state.engine.intake
        Task {
            let result = await intake.ingest([.file(folder)], options: options)
            summary = result
            if state.pendingBatch?.batchID == result.batchID { state.pendingBatch = nil }
            importing = false
        }
    }
}
