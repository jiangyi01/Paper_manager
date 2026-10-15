import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

// P1–P4: Welcome, About you, AI reading, Library. In the preflight nothing here needs the engine.

// MARK: - P1 Welcome

struct WelcomePage: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(title: L.Onb.welcomeTitle)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(L.Onb.welcomePoints.enumerated()), id: \.offset) { _, point in
                    Label { Text(point.1).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: point.0).foregroundStyle(.tint).frame(width: 22)
                    }
                }
            }
            if model.pendingOpens > 0 {
                NoteText(L.Onb.pendingPDFs(model.pendingOpens), symbol: "doc.badge.clock")
            }
            HStack(alignment: .center, spacing: 16) {
                TourIllustration(stepID: "drop", index: 0)
                    .scaleEffect(0.6)
                    .frame(width: 210, height: 100)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.Onb.livesTitle).font(.headline)
                    Text(L.Onb.livesBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if model.mode == .preflight {
                HStack(spacing: 10) {
                    Button(L.Onb.getStarted) { model.go(.about) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    Button(L.Onb.movingFromMac) {
                        model.movingFromAnotherMac = true
                        model.libraryChoice = .existing(SharedPaths.realHome)
                        model.inspected = nil
                        model.go(.about)
                    }
                    Button(L.Onb.setupFile) { model.showImportSheet = true }
                }
                .controlSize(.large)
                VStack(alignment: .leading, spacing: 4) {
                    Button(L.Onb.quickStart) { Task { await model.runQuickStart() } }
                        .buttonStyle(.link)
                        .disabled(model.committing)
                    Text(L.Onb.quickStartNote).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.showImportSheet }, set: { model.showImportSheet = $0 })) {
            SettingsImportSheet(settings: model.settings, fileURL: nil, onClose: { _ in model.showImportSheet = false })
        }
    }
}

// MARK: - P2 About you

struct AboutPage: View {
    let model: OnboardingModel
    @State private var added: Int?
    @State private var adding = false

    var body: some View {
        let config = model.settings.config.snapshot
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(title: L.Onb.aboutTitle)
            // The editor (S2) brings the page's intro, the field grid, stage, reader, interests, the
            // institution picker with its person-sender preview, and the notes.
            ProfileEditor(settings: model.settings, context: .onboarding)
            if model.mode == .revisit, let state = model.state, (state.snapshot?.rows.isEmpty == false) {
                HStack(spacing: 10) {
                    Button(L.Onb.addStarters(config.field.name(L.lang))) {
                        adding = true
                        let pack = config.field.starterCategories
                        Task {
                            added = (try? await state.engine.addMissingStarterCategories(pack)) ?? 0
                            adding = false
                        }
                    }
                    .disabled(adding)
                    if let added { StatusLine(.ok, L.Onb.addedStarters(added)) }
                }
            }
        }
    }
}

// MARK: - P3 AI reading

struct AIPage: View {
    let model: OnboardingModel

    var body: some View {
        let f = model.facts.facts
        VStack(alignment: .leading, spacing: 12) {
            OnboardingHeader(title: L.Onb.aiTitle, subtitle: L.Onb.aiSubtitle)
            providerCard(.claude, title: L.Onb.claudeCard, status: f.ai.statuses[.claude])
            providerCard(.codex, title: L.Onb.codexCard, status: f.ai.statuses[.codex])
            ChoiceCard(selected: model.aiChoice == OnboardingRules.AIChoice.none,
                       action: { model.selectAI(.none) }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.Onb.noneCard).font(.headline)
                    if model.aiChoice == OnboardingRules.AIChoice.none {
                        Text(L.Onb.notNowBody).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let k = model.aiChoice?.provider {
                HStack(spacing: 10) {
                    if let running = model.readingProvider, running == k {
                        StatusLine(.ok, L.Onb.readingOn(k))
                        Button(L.Onb.turnOff) { model.turnOffAI() }.controlSize(.small)
                    } else if let running = model.readingProvider {
                        // The card only shows this provider's help; reading stays with `running`
                        // until the user switches it here.
                        StatusLine(.ok, L.Onb.readingOn(running))
                        Button(L.Onb.switchReading(to: k)) { model.turnOnAI() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(L.Onb.turnOn(k)) { model.turnOnAI() }.buttonStyle(.borderedProminent)
                        Text(L.Onb.turnOnNote).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            NoteText(OrgStrings.aiPolicyLine(org: model.settings.config.snapshot.organization, lang: L.lang), symbol: "building.columns")
        }
        .task { model.facts.kick(providers: true) }
        .onAppear { model.preselectAI() }
        .onChange(of: f.ai.statuses) { _, _ in model.preselectAI() }
    }

    private func providerCard(_ kind: AIProviderKind, title: String, status: ProbeState<ProviderStatus>?) -> some View {
        let choice: OnboardingRules.AIChoice = kind == .claude ? .claude : .codex
        let selected = model.aiChoice == choice
        return ChoiceCard(selected: selected, action: { model.selectAI(choice) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    ProviderStatusBadge(kind: kind, status: status)
                }
                if selected, let s = status?.known {
                    ProviderHelp(kind: kind, status: s, model: model)
                }
            }
        }
    }
}

/// "Signed in · Max" over the tool's path (one line, middle-truncated) / "Not installed" / …
/// (zero-quota detection).
struct ProviderStatusBadge: View {
    let kind: AIProviderKind
    let status: ProbeState<ProviderStatus>?

    var body: some View {
        switch status?.known {
        case .ready(let plan, _, let path)?:
            VStack(alignment: .trailing, spacing: 2) {
                StatusLine(.ok, L.Onb.signedIn(plan: SettingsFormat.plan(plan), path: nil))
                if !path.isEmpty {
                    Text(verbatim: SettingsFormat.tildePath(path))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
        case .notInstalled?:
            StatusLine(.neutral, L.Onb.notInstalled)
        case .notLoggedIn(let code)?:
            if case .nonSubscription = ProviderReason(code: code) {
                StatusLine(.warning, L.Onb.apiKeyLogin)
            } else {
                StatusLine(.warning, L.Onb.notSignedIn)
            }
        case .unsupported?:
            StatusLine(.warning, status?.known?.reasonText(L.lang, provider: kind) ?? "")
        case nil:
            StatusLine(.working, L.Onb.checking)
        }
    }
}

/// Install / sign-in steps for the selected provider (commands only; nothing runs by itself).
private struct ProviderHelp: View {
    let kind: AIProviderKind
    let status: ProviderStatus
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch status {
            case .notInstalled:
                Text(L.Onb.installInTerminal).font(.callout)
                CommandBox(command: kind == .claude ? ClaudeAccountSection.installCommand : L.Pref.codexBrewCommand)
                if kind == .codex { NoteText(L.Onb.codexAppHint) }
                buttons(signIn: false)
            case .notLoggedIn(let code):
                if case .nonSubscription = ProviderReason(code: code) {
                    NoteText(status.reasonText(L.lang, provider: kind))
                }
                Text(L.Onb.signInInTerminal).font(.callout)
                if kind == .claude {
                    NoteText(L.Onb.claudeLoginHint)
                    CommandBox(command: "claude")
                } else {
                    CommandBox(command: CodexBinaryProbe.loginCommand(path: nil))
                }
                buttons(signIn: true)
            case .unsupported:
                NoteText(status.reasonText(L.lang, provider: kind))
                buttons(signIn: false)
            case .ready:
                EmptyView()
            }
            DisclosureGroup(L.Onb.advanced) {
                HStack {
                    Text(kind == .claude ? model.settings.cliPathOverride : model.settings.codexPathOverride)
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Button(L.Onb.customPath) { chooseBinary() }.controlSize(.small)
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func buttons(signIn: Bool) -> some View {
        HStack {
            Button(L.Onb.openTerminal) { SystemLinks.openTerminal() }
            Button(signIn ? L.Onb.iveSignedIn : L.Help.refresh) { recheck() }
        }
        .controlSize(.small)
    }

    private func recheck() {
        if let state = model.state, kind == state.settings.agentProvider {
            let agents = state.engine.agents
            Task { await agents.wake(forceDetect: true) }
        }
        model.facts.kick(providers: true)
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L.Onb.customPathPrompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if kind == .claude { model.settings.cliPathOverride = url.path } else { model.settings.codexPathOverride = url.path }
        model.facts.kick(providers: true)
    }
}

// MARK: - P4 Library

struct LibraryPage: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingHeader(title: L.Onb.libraryTitle, subtitle: L.Onb.librarySubtitle)
            if model.mode == .preflight {
                choices
                problem
            } else {
                current
            }
        }
        .task {
            // Renders and self-tests (fixed facts) never look at this Mac's folders.
            guard model.mode == .preflight, model.facts.fixed == nil else { return }
            let docs = SharedPaths.realHome.appendingPathComponent("Documents", isDirectory: true)
            model.documentsInICloud = await BlockingIO.run { FileOps.isUbiquitous(docs) }
        }
    }

    // Preflight: where the new (or existing) library is.
    @ViewBuilder private var choices: some View {
        let choice = model.libraryChoice
        ChoiceCard(selected: choice == .documents, action: { model.libraryChoice = .documents; model.inspected = nil }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.Onb.optDocuments).font(.headline)
                Text("~/Documents/PaperDeck").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                if choice == .documents {
                    NoteText(L.Onb.tccNote, symbol: "hand.raised")
                    if model.documentsInICloud {
                        NoteText(L.Onb.documentsInICloud, symbol: "icloud")
                        Button(L.Onb.useHomeFolder) { model.libraryChoice = .homeFolder }.controlSize(.small)
                    }
                }
            }
        }
        if model.documentsInICloud || choice == .homeFolder {
            ChoiceCard(selected: choice == .homeFolder, action: { model.libraryChoice = .homeFolder; model.inspected = nil }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.Onb.optHome).font(.headline)
                    Text("~/PaperDeck").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        ChoiceCard(selected: { if case .other = choice { return true }; return false }(),
                   action: { Task { await model.pickLibraryFolder(existing: false) } }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.Onb.optOther).font(.headline)
                if case .other(let url) = choice {
                    Text(SettingsFormat.tildePath(url.path)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    classification(url)
                }
            }
        }
        ChoiceCard(selected: { if case .existing = choice { return true }; return false }(),
                   action: { Task { await model.pickLibraryFolder(existing: true) } }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.Onb.optExisting).font(.headline)
                if case .existing(let url) = choice {
                    existingLine(url)
                }
                if model.movingFromAnotherMac {
                    NoteText(L.Onb.movingNote, symbol: "arrow.right.arrow.left")
                    Button(L.Help.importSettings) { model.showImportSheet = true }.controlSize(.small)
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.showImportSheet }, set: { model.showImportSheet = $0 })) {
            SettingsImportSheet(settings: model.settings, fileURL: nil, onClose: { _ in model.showImportSheet = false })
        }
    }

    @ViewBuilder private func classification(_ url: URL) -> some View {
        switch model.inspected {
        case .existingLibrary(_, let n)?: NoteText(L.Onb.foundLibrary(n), symbol: "books.vertical")
        case .otherContent?: NoteText(L.Onb.classifyOther, symbol: "folder")
        default: EmptyView()
        }
        if url.path.contains("/Library/CloudStorage/") || url.path.contains("/Mobile Documents/") {
            NoteText(L.Onb.classifyCloud, symbol: "icloud")
        } else if url.path.hasPrefix("/Volumes/") {
            NoteText(L.Onb.classifyRemovable, symbol: "externaldrive")
        }
    }

    @ViewBuilder private func existingLine(_ url: URL) -> some View {
        switch model.inspected {
        case .existingLibrary(_, let n)?:
            Text(SettingsFormat.tildePath(url.path)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            StatusLine(.ok, L.Onb.foundLibrary(n))
        case .parentOfLibrary(let child, _)?:
            HStack {
                Text(L.Onb.didYouMean(SettingsFormat.tildePath(child.path)))
                Button(L.Onb.useIt) { model.applyPicked(child, kind: .existingLibrary(libraryID: nil, cardCount: 0), existing: true) }
                    .controlSize(.small)
            }
        case nil:
            EmptyView()
        default:
            StatusLine(.warning, L.Onb.noLibraryHere)
            HStack {
                Button(L.Onb.chooseAnother) { Task { await model.pickLibraryFolder(existing: true) } }
                Button(L.Onb.createHere) { model.libraryChoice = .other(url); model.inspected = .otherContent(items: 1) }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var problem: some View {
        switch model.libraryProblem {
        case .denied?:
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(.error, L.Onb.deniedInline)
                HStack {
                    Button(L.Onb.openPrivacy) { SystemLinks.filesAndFolders() }
                    Button(L.Onb.chooseAnotherFolder) { Task { await model.pickLibraryFolder(existing: false) } }
                    Button(L.Onb.retry) { Task { await model.commit() } }
                }
                .controlSize(.small)
            }
        case .missingParent?: StatusLine(.error, L.Onb.missingParent)
        case .readOnly?: StatusLine(.error, L.Onb.readOnly)
        case nil: EmptyView()
        }
    }

    // Live / revisit: the library in use.
    @ViewBuilder private var current: some View {
        let f = model.facts.facts
        let path = model.state.map { SettingsFormat.tildePath($0.engine.paths.library.path) }
            ?? SettingsFormat.tildePath(model.settings.libraryPath)
        VStack(alignment: .leading, spacing: 10) {
            Text(L.Onb.currentLibrary).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            switch GuideEvaluator.evaluate(.libraryUsable, f) {
            case .done: StatusLine(.ok, L.Onb.paperCount(model.state?.snapshot?.rows.count ?? 0))
            case .problem(let why): StatusLine(.error, why(L.lang))
            default: StatusLine(.working, L.Onb.checking)
            }
            HStack {
                Button(L.Onb.changeLocation) { model.state?.router.showSettings("library") }
                    .disabled(model.state == nil)
                HelpButton(.libraryLocation)
            }
            if model.guide.libraryPendingAction != nil {
                NoteText(L.Onb.restartPending, symbol: "arrow.clockwise.circle")
                Button(L.Onb.restartNow) { Relaunch.now() }.buttonStyle(.borderedProminent)
            }
        }
    }
}
